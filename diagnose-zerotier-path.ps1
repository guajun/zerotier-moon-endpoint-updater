[CmdletBinding()]
param(
    [ValidatePattern('^[0-9a-fA-F]{10}$')]
    [string[]] $MoonNodeId = @(),

    [string[]] $Target = @(),

    [string[]] $PublicFallback = @(),

    [ValidateRange(5, 120)]
    [int] $ObserveSeconds = 20,

    [ValidateRange(5, 600)]
    [int] $FreshSeconds = 60,

    [string] $UdpDnsServer = '223.5.5.5',

    [switch] $ActiveProbe,

    [string] $OutputFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ReportLines = New-Object 'System.Collections.Generic.List[string]'

function Write-ReportLine {
    param([string] $Message = '')

    Write-Host $Message
    $script:ReportLines.Add($Message)
}

function Get-ObjectProperty {
    param(
        [object] $InputObject,
        [string] $Name,
        [object] $Default = $null
    )

    if ($null -ne $InputObject -and $null -ne $InputObject.PSObject.Properties[$Name]) {
        return $InputObject.$Name
    }
    return $Default
}

function Find-ZeroTierCli {
    $command = Get-Command 'zerotier-cli' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $candidates = @(
        "${env:ProgramFiles(x86)}\ZeroTier\One\zerotier-cli.bat",
        "$env:ProgramFiles\ZeroTier\One\zerotier-cli.bat"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    throw 'zerotier-cli was not found. Install ZeroTier and run this script from an elevated PowerShell window.'
}

function Invoke-ZeroTierJson {
    param(
        [string] $CliPath,
        [string] $Command
    )

    $raw = @(& $CliPath '-j' $Command 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($raw | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        throw "zerotier-cli $Command failed: $text"
    }
    try {
        return $text | ConvertFrom-Json
    }
    catch {
        throw "zerotier-cli $Command returned invalid JSON: $text"
    }
}

function Get-ZeroTierSnapshot {
    param(
        [string] $CliPath,
        [int] $FreshWindowSeconds,
        [int64] $ReceiveNotBeforeMs = 0
    )

    $info = Invoke-ZeroTierJson -CliPath $CliPath -Command 'info'
    $peers = @(Invoke-ZeroTierJson -CliPath $CliPath -Command 'peers')
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $peerRows = @()

    foreach ($peer in $peers) {
        $address = ([string](Get-ObjectProperty -InputObject $peer -Name 'address' -Default '')).ToLowerInvariant()
        $role = ([string](Get-ObjectProperty -InputObject $peer -Name 'role' -Default 'UNKNOWN')).ToUpperInvariant()
        $latency = Get-ObjectProperty -InputObject $peer -Name 'latency' -Default -1
        $tunneled = [bool](Get-ObjectProperty -InputObject $peer -Name 'tunneled' -Default $false)
        $activePaths = @()

        foreach ($path in @(Get-ObjectProperty -InputObject $peer -Name 'paths' -Default @())) {
            $active = [bool](Get-ObjectProperty -InputObject $path -Name 'active' -Default $false)
            $expired = [bool](Get-ObjectProperty -InputObject $path -Name 'expired' -Default $false)
            if ($active -and -not $expired) {
                $lastReceive = [int64](Get-ObjectProperty -InputObject $path -Name 'lastReceive' -Default 0)
                $receiveAgeSeconds = $null
                if ($lastReceive -gt 0 -and $nowMs -ge $lastReceive) {
                    $receiveAgeSeconds = [math]::Round(($nowMs - $lastReceive) / 1000.0, 1)
                }
                $activePaths += [pscustomobject]@{
                    Address = [string](Get-ObjectProperty -InputObject $path -Name 'address' -Default '')
                    Preferred = [bool](Get-ObjectProperty -InputObject $path -Name 'preferred' -Default $false)
                    LastReceive = $lastReceive
                    ReceiveAgeSeconds = $receiveAgeSeconds
                }
            }
        }

        $bestPath = $null
        if ($activePaths.Count -gt 0) {
            $bestPath = $activePaths |
                Sort-Object @{ Expression = { if ($_.Preferred) { 0 } else { 1 } } },
                    @{ Expression = { if ($null -eq $_.ReceiveAgeSeconds) { [double]::PositiveInfinity } else { $_.ReceiveAgeSeconds } } } |
                Select-Object -First 1
        }

        $fresh = $false
        foreach ($path in $activePaths) {
            if ($null -ne $path.ReceiveAgeSeconds -and
                $path.ReceiveAgeSeconds -le $FreshWindowSeconds -and
                ($ReceiveNotBeforeMs -eq 0 -or $path.LastReceive -ge $ReceiveNotBeforeMs)) {
                $fresh = $true
            }
        }

        $peerRows += [pscustomobject]@{
            Address = $address
            Role = $role
            Latency = $latency
            Direct = ($activePaths.Count -gt 0)
            Fresh = $fresh
            Tunneled = $tunneled
            Path = if ($null -ne $bestPath) { $bestPath.Address } else { '-' }
            ReceiveAgeSeconds = if ($null -ne $bestPath) { $bestPath.ReceiveAgeSeconds } else { $null }
        }
    }

    $online = [bool](Get-ObjectProperty -InputObject $info -Name 'online' -Default $false)
    return [pscustomobject]@{
        Time = Get-Date
        Online = $online
        Address = [string](Get-ObjectProperty -InputObject $info -Name 'address' -Default '-')
        Version = [string](Get-ObjectProperty -InputObject $info -Name 'version' -Default '-')
        Peers = $peerRows
    }
}

function Merge-PeerEvidence {
    param(
        [hashtable] $Evidence,
        [object] $Snapshot
    )

    foreach ($peer in $Snapshot.Peers) {
        if (-not $Evidence.ContainsKey($peer.Address)) {
            $Evidence[$peer.Address] = [pscustomobject]@{
                Address = $peer.Address
                Role = $peer.Role
                Direct = $false
                Fresh = $false
                Tunneled = $false
                MinReceiveAgeSeconds = $null
                Latency = $peer.Latency
                Paths = New-Object 'System.Collections.Generic.HashSet[string]'
            }
        }
        $item = $Evidence[$peer.Address]
        $item.Role = $peer.Role
        $item.Direct = $item.Direct -or $peer.Direct
        $item.Fresh = $item.Fresh -or $peer.Fresh
        $item.Tunneled = $item.Tunneled -or $peer.Tunneled
        $item.Latency = $peer.Latency
        if ($peer.Path -ne '-') {
            [void]$item.Paths.Add($peer.Path)
        }
        if ($null -ne $peer.ReceiveAgeSeconds -and
            ($null -eq $item.MinReceiveAgeSeconds -or $peer.ReceiveAgeSeconds -lt $item.MinReceiveAgeSeconds)) {
            $item.MinReceiveAgeSeconds = $peer.ReceiveAgeSeconds
        }
    }
}

function Test-VirtualTarget {
    param([string] $Destination)

    $latencies = @()
    $success = 0
    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        for ($i = 0; $i -lt 4; $i++) {
            try {
                $reply = $ping.Send($Destination, 1500)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $success++
                    $latencies += [int64]$reply.RoundtripTime
                }
            }
            catch {
                # The aggregate result below is enough for diagnosis.
            }
        }
    }
    finally {
        $ping.Dispose()
    }

    return [pscustomobject]@{
        Destination = $Destination
        Success = $success
        Sent = 4
        MinimumMs = if ($latencies.Count -gt 0) { ($latencies | Measure-Object -Minimum).Minimum } else { $null }
        AverageMs = if ($latencies.Count -gt 0) { [math]::Round(($latencies | Measure-Object -Average).Average, 1) } else { $null }
        MaximumMs = if ($latencies.Count -gt 0) { ($latencies | Measure-Object -Maximum).Maximum } else { $null }
    }
}

function Split-TcpEndpoint {
    param([string] $Endpoint)

    if ($Endpoint -notmatch '^(.+):(\d+)$') {
        throw "invalid public fallback endpoint '$Endpoint'; use host:port"
    }
    $port = [int]$Matches[2]
    if ($port -lt 1 -or $port -gt 65535) {
        throw "invalid TCP port in public fallback endpoint '$Endpoint'"
    }
    return [pscustomobject]@{ HostName = $Matches[1]; Port = $port }
}

function Test-TcpEndpoint {
    param(
        [string] $Endpoint,
        [int] $TimeoutMs = 3000
    )

    $parts = Split-TcpEndpoint -Endpoint $Endpoint
    $client = New-Object System.Net.Sockets.TcpClient
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $async = $client.BeginConnect($parts.HostName, $parts.Port, $null, $null)
        $connected = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($connected) {
            $client.EndConnect($async)
        }
        return [pscustomobject]@{
            Endpoint = $Endpoint
            Success = ($connected -and $client.Connected)
            ElapsedMs = $timer.ElapsedMilliseconds
            Error = if ($connected -and $client.Connected) { '' } else { 'timeout or refused' }
        }
    }
    catch {
        return [pscustomobject]@{
            Endpoint = $Endpoint
            Success = $false
            ElapsedMs = $timer.ElapsedMilliseconds
            Error = $_.Exception.Message
        }
    }
    finally {
        $timer.Stop()
        $client.Dispose()
    }
}

function Test-UdpDns {
    param(
        [string] $Server,
        [int] $TimeoutMs = 3000
    )

    $random = New-Object System.Random
    $transactionId = $random.Next(0, 65536)
    $packet = New-Object 'System.Collections.Generic.List[byte]'
    foreach ($value in @(
        (($transactionId -shr 8) -band 0xff), ($transactionId -band 0xff),
        0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    )) {
        $packet.Add([byte]$value)
    }
    foreach ($label in 'example.com'.Split('.')) {
        $bytes = [Text.Encoding]::ASCII.GetBytes($label)
        $packet.Add([byte]$bytes.Length)
        foreach ($value in $bytes) {
            $packet.Add($value)
        }
    }
    foreach ($value in @(0x00, 0x00, 0x01, 0x00, 0x01)) {
        $packet.Add([byte]$value)
    }

    $udp = New-Object System.Net.Sockets.UdpClient
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($Server, 53)
        [void]$udp.Send($packet.ToArray(), $packet.Count)
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $response = $udp.Receive([ref]$remote)
        $valid = $response.Length -ge 12 -and
            $response[0] -eq (($transactionId -shr 8) -band 0xff) -and
            $response[1] -eq ($transactionId -band 0xff) -and
            (($response[2] -band 0x80) -ne 0)
        return [pscustomobject]@{
            Server = "$Server`:53"
            Success = $valid
            ElapsedMs = $timer.ElapsedMilliseconds
            Error = if ($valid) { '' } else { 'invalid DNS response' }
        }
    }
    catch {
        return [pscustomobject]@{
            Server = "$Server`:53"
            Success = $false
            ElapsedMs = $timer.ElapsedMilliseconds
            Error = $_.Exception.Message
        }
    }
    finally {
        $timer.Stop()
        $udp.Dispose()
    }
}

function Get-Diagnosis {
    param(
        [bool] $DidActiveProbe,
        [bool] $PlanetFresh,
        [bool] $MoonFresh,
        [bool] $AnyOnline,
        [bool] $UdpDnsWorks,
        [bool] $AnyPublicFallbackWorks
    )

    if ($PlanetFresh) {
        return [pscustomobject]@{
            Code = 0
            Label = 'PASS'
            Message = 'An official Planet exchanged traffic during the observation window. Planet access is working.'
        }
    }
    if (-not $DidActiveProbe) {
        return [pscustomobject]@{
            Code = 3
            Label = 'INCONCLUSIVE'
            Message = 'No recent Planet receive was observed passively. Run again with -ActiveProbe to force a clean bootstrap test.'
        }
    }
    if ($MoonFresh) {
        return [pscustomobject]@{
            Code = 2
            Label = 'SUSPECTED_PLANET_FILTER'
            Message = 'ZeroTier UDP reached a Moon after restart, but no official Planet replied. Planet-specific routing or filtering is likely.'
        }
    }
    if ($AnyOnline) {
        return [pscustomobject]@{
            Code = 3
            Label = 'INCONCLUSIVE'
            Message = 'ZeroTier reported ONLINE, but neither a fresh Planet nor a fresh Moon path was captured. Increase -ObserveSeconds and retry.'
        }
    }
    if ($UdpDnsWorks -or $AnyPublicFallbackWorks) {
        return [pscustomobject]@{
            Code = 3
            Label = 'ZEROTIER_UDP_UNAVAILABLE'
            Message = 'General connectivity works, but no ZeroTier root replied. Check PassWall, local firewall, NAT, and UDP/9993 before blaming Planet addresses.'
        }
    }
    return [pscustomobject]@{
        Code = 3
        Label = 'GENERAL_CONNECTIVITY_FAILURE'
        Message = 'Neither ZeroTier roots nor the control probes replied. Diagnose the local Internet connection first.'
    }
}

function Invoke-Diagnosis {
    $cliPath = Find-ZeroTierCli
    Write-ReportLine 'ZeroTier path diagnostic'
    Write-ReportLine ("Time: {0:yyyy-MM-dd HH:mm:ss zzz}" -f (Get-Date))
    Write-ReportLine "CLI: $cliPath"
    Write-ReportLine "Mode: $(if ($ActiveProbe) { 'active service restart' } else { 'passive observation' })"
    Write-ReportLine ''

    $evidence = @{}
    $snapshots = @()
    $first = Get-ZeroTierSnapshot -CliPath $cliPath -FreshWindowSeconds $FreshSeconds
    $receiveNotBeforeMs = 0

    if ($ActiveProbe) {
        $service = Get-Service -Name 'ZeroTierOneService' -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            throw 'Windows service ZeroTierOneService was not found.'
        }
        Write-ReportLine 'Active probe: restarting ZeroTier One once...'
        Write-ReportLine ("Before restart: ONLINE={0}, Planet peers={1}, Moon peers={2}" -f
            $first.Online,
            @($first.Peers | Where-Object { $_.Role -eq 'PLANET' }).Count,
            @($first.Peers | Where-Object { $_.Role -eq 'MOON' -or $_.Role -eq 'ROOT' }).Count)
        $receiveNotBeforeMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Restart-Service -Name 'ZeroTierOneService' -Force
        (Get-Service -Name 'ZeroTierOneService').WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
        Start-Sleep -Seconds 2
    }
    else {
        $snapshots += $first
        Merge-PeerEvidence -Evidence $evidence -Snapshot $first
    }

    $pingResults = @()
    foreach ($destination in $Target) {
        $pingResults += Test-VirtualTarget -Destination $destination
    }

    $deadline = (Get-Date).AddSeconds($ObserveSeconds)
    do {
        $snapshot = Get-ZeroTierSnapshot -CliPath $cliPath -FreshWindowSeconds $FreshSeconds `
            -ReceiveNotBeforeMs $receiveNotBeforeMs
        $snapshots += $snapshot
        Merge-PeerEvidence -Evidence $evidence -Snapshot $snapshot
        if ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
        }
    } while ((Get-Date) -lt $deadline)

    $udpDns = Test-UdpDns -Server $UdpDnsServer
    $fallbackResults = @()
    foreach ($endpoint in $PublicFallback) {
        $fallbackResults += Test-TcpEndpoint -Endpoint $endpoint
    }

    Write-ReportLine 'ZeroTier service:'
    Write-ReportLine ("  Node: {0}  Version: {1}  ONLINE observed: {2}" -f
        $snapshots[-1].Address, $snapshots[-1].Version, [bool]($snapshots | Where-Object { $_.Online }))
    Write-ReportLine ''
    Write-ReportLine 'Root peer evidence observed during this run:'
    Write-ReportLine '  NODE ID     ROLE    DIRECT  FRESH RX  TUNNEL  BEST RX AGE  PATHS'

    $expectedMoonIds = @($MoonNodeId | ForEach-Object { $_.ToLowerInvariant() })
    $rootRows = @($evidence.Values | Where-Object {
        $_.Role -eq 'PLANET' -or $_.Role -eq 'MOON' -or $_.Role -eq 'ROOT' -or $expectedMoonIds -contains $_.Address
    } | Sort-Object Role, Address)
    foreach ($row in $rootRows) {
        $age = if ($null -eq $row.MinReceiveAgeSeconds) { '-' } else { "{0:N1}s" -f $row.MinReceiveAgeSeconds }
        $paths = if ($row.Paths.Count -gt 0) { (@($row.Paths) -join ',') } else { '-' }
        Write-ReportLine ("  {0,-11} {1,-7} {2,-7} {3,-9} {4,-7} {5,-12} {6}" -f
            $row.Address, $row.Role, $row.Direct, $row.Fresh, $row.Tunneled, $age, $paths)
    }
    foreach ($moonId in $expectedMoonIds) {
        if (-not $evidence.ContainsKey($moonId)) {
            Write-ReportLine ("  {0,-11} {1,-7} {2,-7} {3,-9} {4,-7} {5,-12} {6}" -f
                $moonId, 'MOON?', $false, $false, $false, '-', 'not present in peer table')
        }
    }
    if ($rootRows.Count -eq 0 -and $expectedMoonIds.Count -eq 0) {
        Write-ReportLine '  No Planet or Moon peer was present.'
    }

    if ($pingResults.Count -gt 0) {
        Write-ReportLine ''
        Write-ReportLine 'ZeroTier target pings:'
        foreach ($result in $pingResults) {
            Write-ReportLine ("  {0}: {1}/{2} replies, min/avg/max={3}/{4}/{5} ms" -f
                $result.Destination, $result.Success, $result.Sent,
                $(if ($null -eq $result.MinimumMs) { '-' } else { $result.MinimumMs }),
                $(if ($null -eq $result.AverageMs) { '-' } else { $result.AverageMs }),
                $(if ($null -eq $result.MaximumMs) { '-' } else { $result.MaximumMs }))
        }
    }

    Write-ReportLine ''
    Write-ReportLine ("Control UDP DNS {0}: success={1}, elapsed={2} ms{3}" -f
        $udpDns.Server, $udpDns.Success, $udpDns.ElapsedMs,
        $(if ($udpDns.Error) { ", error=$($udpDns.Error)" } else { '' }))
    if ($fallbackResults.Count -gt 0) {
        Write-ReportLine 'Public fallback TCP:'
        foreach ($result in $fallbackResults) {
            Write-ReportLine ("  {0}: success={1}, elapsed={2} ms{3}" -f
                $result.Endpoint, $result.Success, $result.ElapsedMs,
                $(if ($result.Error) { ", error=$($result.Error)" } else { '' }))
        }
    }

    $planetFresh = [bool]($evidence.Values | Where-Object { $_.Role -eq 'PLANET' -and $_.Fresh })
    $moonFresh = [bool]($evidence.Values | Where-Object {
        ($_.Role -eq 'MOON' -or $_.Role -eq 'ROOT' -or $expectedMoonIds -contains $_.Address) -and $_.Fresh
    })
    $anyOnline = [bool]($snapshots | Where-Object { $_.Online })
    $anyFallback = [bool]($fallbackResults | Where-Object { $_.Success })
    $diagnosis = Get-Diagnosis -DidActiveProbe $ActiveProbe.IsPresent -PlanetFresh $planetFresh `
        -MoonFresh $moonFresh -AnyOnline $anyOnline -UdpDnsWorks $udpDns.Success `
        -AnyPublicFallbackWorks $anyFallback

    Write-ReportLine ''
    Write-ReportLine "RESULT: $($diagnosis.Label)"
    Write-ReportLine $diagnosis.Message
    Write-ReportLine 'A DNS UDP success only proves that some UDP works; a fresh Moon path is the stronger Planet-specific comparison.'

    if ($OutputFile) {
        $fullPath = [IO.Path]::GetFullPath($OutputFile)
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllLines($fullPath, $script:ReportLines, $encoding)
        Write-Host "Report saved to $fullPath"
    }

    return $diagnosis.Code
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        exit (Invoke-Diagnosis)
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}
