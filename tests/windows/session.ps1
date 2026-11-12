#Requires -Version 5.1
#Requires -RunAsAdministrator
# Run a complete disposable VM test with a return checkpoint and unconditional cleanup.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('dev', 'smoke')][string]$Scenario,
    [Parameter(Mandatory = $true)][string]$VmName,
    [Parameter(Mandatory = $true)][string]$BaselineCheckpoint,
    [Parameter(Mandatory = $true)][string]$Payload,
    [Parameter(Mandatory = $true)][string]$CredentialScript,
    [string]$CredentialFunction = 'Get-VmCredential',
    [string]$CredentialUser = '',
    [string]$RunDir = '',
    [string]$GuestModules = 'core,memory',
    [string]$CommitterName = '',
    [string]$CommitterEmail = '',
    [int]$ProxyPort = 17892,
    [int]$UpstreamPort = 7890,
    [switch]$NoProxy,
    [switch]$SkipKnowledge
)
$ErrorActionPreference = 'Stop'
$driver = Join-Path $PSScriptRoot 'run.ps1'
if (-not $RunDir) { $RunDir = Join-Path $env:TEMP ('akis-pi-session-' + [guid]::NewGuid().ToString('N')) }
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
$common = @{
    VmName = $VmName; RunDir = $RunDir; CredentialScript = $CredentialScript
    CredentialFunction = $CredentialFunction; CredentialUser = $CredentialUser
    ProxyPort = $ProxyPort; UpstreamPort = $UpstreamPort
}
function Invoke-Driver {
    param([string]$Action, [hashtable]$Options = @{})
    & $driver -Action $Action @common @Options
    if ($LASTEXITCODE -ne 0) { throw ('driver ' + $Action + ' exited ' + $LASTEXITCODE) }
}
$returnCheckpoint = $BaselineCheckpoint
$protected = $false
$restoreNeeded = $false
$failure = ''
$cleanupErrors = @()
try {
    if ($Scenario -eq 'smoke') {
        $returnCheckpoint = 'akis-pre-' + ((Get-Date).ToString('s').Replace(':', '').Replace('-', '')) + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        Invoke-Driver protect @{ Checkpoint = $returnCheckpoint }
        $protected = $true
    }
    # Set before the first destructive transition, so partial failures still restore.
    $restoreNeeded = $true
    Invoke-Driver stop
    Invoke-Driver restore @{ Checkpoint = $BaselineCheckpoint }
    Invoke-Driver start
    Invoke-Driver bridge @{ NoProxy = $NoProxy }
    Invoke-Driver copy @{ Payload = $Payload }
    foreach ($step in @('prereq', 'render', 'knowledge', 'packages', 'stub', 'doctor', 'summary')) {
        Invoke-Driver exec @{ GuestStep = $step; GuestModules = $GuestModules; GuestCommitterName = $CommitterName; GuestCommitterEmail = $CommitterEmail; SkipKnowledge = $SkipKnowledge; ActionTimeoutMinutes = 12 }
    }
} catch {
    $failure = $_.Exception.Message
} finally {
    if ($restoreNeeded) {
        # Each cleanup is independent: a failed collection must never skip stop/restore.
        foreach ($action in @('collect', 'unbridge', 'stop', 'restore')) {
            try {
                $options = @{}
                if ($action -eq 'collect') { $options.KeepRunning = $true }
                if ($action -eq 'restore') { $options.Checkpoint = $returnCheckpoint }
                Invoke-Driver $action $options
            } catch { $cleanupErrors += $action + ': ' + $_.Exception.Message }
        }
    }
    $report = [ordered]@{
        scenario = $Scenario; baselineCheckpoint = $BaselineCheckpoint
        returnCheckpoint = $returnCheckpoint; protectionCreated = $protected
        protectionRetained = $protected; failure = $failure; cleanupErrors = $cleanupErrors
        ok = (-not $failure -and $cleanupErrors.Count -eq 0)
    }
    [IO.File]::WriteAllText((Join-Path $RunDir 'session.json'), ($report | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}
if (-not $report.ok) { Write-Error ($failure + '; ' + ($cleanupErrors -join '; ')) -ErrorAction Continue; exit 1 }
exit 0
