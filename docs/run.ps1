$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdministrator) {
    throw 'Open PowerShell as Administrator, then run the command again.'
}

$assetUrl = 'https://github.com/guajun/zerotier-moon-endpoint-updater/releases/latest/download/diagnose-zerotier-path.ps1'
$downloadDir = Join-Path $env:TEMP 'zerotier-path-diagnostic'
$diagnosticPath = Join-Path $downloadDir 'diagnose-zerotier-path.ps1'
$desktop = [Environment]::GetFolderPath('Desktop')
$reportPath = Join-Path $desktop ("zerotier-diagnostic-{0:yyyyMMdd-HHmmss}.txt" -f (Get-Date))

New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri $assetUrl -OutFile $diagnosticPath
Unblock-File -LiteralPath $diagnosticPath

Write-Host 'Downloaded the latest diagnostic release.' -ForegroundColor Cyan
Write-Host 'ZeroTier will restart once for a clean Planet bootstrap test.' -ForegroundColor Yellow

$env:ZT_DIAGNOSTIC_PATH = $diagnosticPath
$env:ZT_DIAGNOSTIC_REPORT = $reportPath
$childCommand = @'
& $env:ZT_DIAGNOSTIC_PATH `
    -ActiveProbe `
    -ObserveSeconds 30 `
    -MoonNodeId @('a8bb5c9ace', '95bdf667d0') `
    -Target @('10.244.204.233', '10.244.161.185') `
    -OutputFile $env:ZT_DIAGNOSTIC_REPORT
exit $LASTEXITCODE
'@
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
& powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand

$diagnosticExitCode = $LASTEXITCODE
Remove-Item Env:ZT_DIAGNOSTIC_PATH, Env:ZT_DIAGNOSTIC_REPORT -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "Report: $reportPath" -ForegroundColor Cyan
Write-Host "Diagnostic exit code: $diagnosticExitCode"
