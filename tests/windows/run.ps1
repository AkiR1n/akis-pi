#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
  tests/windows/run.ps1 -- host side driver for one Hyper-V Windows VM used to test
  this package. One -Action per remote (ssh) invocation, so a single call stays well
  under a 12 minute budget.

  Everything host specific is a parameter: the VM name, the checkpoint names, the path
  to a credential script and its function, the proxy port. This file contains no
  machine name, no user name, no drive letter of a private tree.

  Actions
    protect  create a protection checkpoint of the VM's current state. Default name is
             akis-pre-<yyyymmdd-hhmmss>; pass -Checkpoint to choose the name. Nothing is
             deleted afterwards: the operator decides when the checkpoint goes away.
    restore  refuse unless the VM is Off, then restore -Checkpoint. No disk copying is
             done anywhere in this script.
    start    start the VM (refuse unless Off or already Running), wait for PowerShell
             Direct, and record a guest fingerprint (OS, PowerShell, user profile path
             ASCII or not, node/git presence).
    bridge   give the guest a route to the host proxy without touching the proxy: one
             netsh portproxy v4tov4 entry (-ProxyPort -> 127.0.0.1:-UpstreamPort) and one
             inbound firewall rule named -RuleName. Both are read back and proven end to
             end from the host, then the guest gets HKCU system proxy + HTTP(S)_PROXY so
             npm, git and Invoke-WebRequest all use it. Pass -NoProxy to skip entirely.
    copy     archive the payload directory (top level .git and any node_modules excluded),
             copy it into the guest, expand it, and compare a sha256 manifest on both
             sides. Mismatch exits 3.
    exec     run guest-deploy.ps1 with Process-scoped RemoteSigned and a hard deadline.
             Group policy restrictions fail explicitly. The payload writes RESULT=<n>
             because exit would kill the remote session.
    collect  mirror the guest result directory back into the run directory, then (unless
             -KeepRunning) shut the guest down, wait for Off, and unbridge.
    unbridge remove exactly the portproxy entry and firewall rule this script created,
             clear the guest proxy, and re-read both tables. Leftovers exit 6.
    stop     graceful guest shutdown, wait for Off, fall back to Stop-VM -Force.

  Run directory: -RunDir, or %TEMP%\akis-pi-vm-runs\<stamp> remembered in current.txt so
  later calls find it again. Contains run.log plus one JSON per action.

  Credentials: dot-source -CredentialScript and call -CredentialFunction. The function
  must return a PSCredential; if it has a -User parameter, -CredentialUser is passed to
  it. A password is only ever held in memory and handed to New-PSSession: never printed,
  never logged, never written to a file.

  Exit codes: 0 ok, 2 precondition, 3 guest/payload failure, 4 deadline, 5 proxy bridge,
              6 cleanup incomplete, 1 unexpected.

  ASCII only: Windows PowerShell 5.1 reads a BOM-less .ps1 as the ANSI code page, so a
  non-ASCII literal here would be corrupted. Keep it that way.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('protect', 'restore', 'start', 'bridge', 'copy', 'exec', 'collect', 'unbridge', 'stop')]
    [string]$Action,
    [Parameter(Mandatory = $true)][string]$VmName,
    [string]$Checkpoint = '',
    [string]$Payload = '',
    [string]$GuestPayloadDir = 'C:\akis-pi-test\payload',
    [string]$GuestOutDir = 'C:\akis-pi-test\out',
    [string]$RunDir = '',
    [string]$CredentialScript = '',
    [string]$CredentialFunction = 'Get-VmCredential',
    [string]$CredentialUser = '',
    [int]$ProxyPort = 17892,
    [int]$UpstreamPort = 7890,
    [string]$SwitchAlias = 'vEthernet (Default Switch)',
    [string]$RuleName = 'akis-pi-test-proxy-bridge',
    [string]$GuestScript = 'tests\windows\guest-deploy.ps1',
    [string]$GuestStep = 'prereq',
    [string]$GuestModules = 'core,memory',
    [string]$GuestCommitterName = '',
    [string]$GuestCommitterEmail = '',
    [string]$GuestAgentDir = '',
    [int]$GuestStubPort = 18899,
    [switch]$SkipKnowledge,
    [switch]$NoProxy,
    [switch]$KeepRunning,
    [int]$DirectTimeoutMinutes = 8,
    [int]$ActionTimeoutMinutes = 10,
    [int]$ShutdownTimeoutMinutes = 8
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Now = Get-Date
$script:Stamp = ('{0:d2}{1:d2}{2:d2}-{3:d2}{4:d2}{5:d2}' -f $script:Now.Year, $script:Now.Month, $script:Now.Day, $script:Now.Hour, $script:Now.Minute, $script:Now.Second)
$script:Result = [ordered]@{
    action            = $Action
    startedLocal      = (Get-Date).ToString('s')
    finishedLocal     = ''
    ok                = $false
    error             = ''
    exitCode          = 0
    host              = [string]$env:COMPUTERNAME
    vmName            = $VmName
    checkpoint        = $Checkpoint
    runDir            = ''
    vmStateBefore     = ''
    vmStateAfter      = ''
    checkpointsBefore = @()
    checkpointsAfter  = @()
    notes             = @()
}

# ---------------------------------------------------------------------------
# run directory and logging
# ---------------------------------------------------------------------------
function Resolve-RunDirectory {
    if (-not [string]::IsNullOrEmpty($RunDir)) {
        if (-not (Test-Path -LiteralPath $RunDir)) { New-Item -ItemType Directory -Force -Path $RunDir | Out-Null }
        return $RunDir
    }
    $root = Join-Path (Join-Path $env:TEMP 'akis-pi-vm-runs') ($VmName -replace '[^A-Za-z0-9_.-]', '_')
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
    $pointer = Join-Path $root 'current.txt'
    if (Test-Path -LiteralPath $pointer) {
        $cached = ([IO.File]::ReadAllText($pointer)).Trim()
        if (-not [string]::IsNullOrEmpty($cached) -and (Test-Path -LiteralPath $cached)) { return $cached }
    }
    $fresh = Join-Path $root $script:Stamp
    New-Item -ItemType Directory -Force -Path $fresh | Out-Null
    [IO.File]::WriteAllText($pointer, $fresh, $script:Utf8NoBom)
    return $fresh
}

function Write-RunLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = (Get-Date).ToString('s') + ' ' + $Message
    $logPath = Join-Path $script:Result.runDir 'run.log'
    [IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, $script:Utf8NoBom)
    Write-Host $line
}

function Write-RunJson {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Object
    )
    $path = Join-Path $script:Result.runDir $Name
    [IO.File]::WriteAllText($path, ($Object | ConvertTo-Json -Depth 12), $script:Utf8NoBom)
}

function Read-RunJson {
    param([Parameter(Mandatory = $true)][string]$Name)
    $path = Join-Path $script:Result.runDir $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# VM state
# ---------------------------------------------------------------------------
function Get-VmStateName {
    param([Parameter(Mandatory = $true)][string]$Name)
    $vm = Get-VM -Name $Name -ErrorAction Stop
    return [string]$vm.State
}

function Get-CheckpointNames {
    param([Parameter(Mandatory = $true)][string]$Name)
    $list = @()
    try {
        $list = @(Get-VMCheckpoint -VMName $Name -ErrorAction Stop | ForEach-Object {
            [ordered]@{
                name         = [string]$_.Name
                creationTime = $_.CreationTime.ToString('s')
                type         = [string]$_.CheckpointType
                state        = [string]$_.State
                parent       = [string]$_.ParentCheckpointName
            }
        })
    } catch {
        $list = @([ordered]@{ error = $_.Exception.Message })
    }
    return $list
}

function Stop-WithExit {
    param(
        [Parameter(Mandatory = $true)][int]$Code,
        [string]$Message = ''
    )
    if (-not [string]::IsNullOrEmpty($Message)) {
        $script:Result.error = $Message
        Write-RunLog ('[error] ' + $Message)
    }
    $script:ExitCode = $Code
    $script:Result.exitCode = $Code
    $script:Result.ok = ($Code -eq 0)
    $script:Result.finishedLocal = (Get-Date).ToString('s')
    try { $script:Result.vmStateAfter = (Get-VmStateName -Name $VmName) } catch { }
    Write-RunJson -Name ($Action + '.json') -Object $script:Result
    Write-RunLog ('[done] action=' + $Action + ' exit=' + $Code)
    exit $Code
}

# ---------------------------------------------------------------------------
# PowerShell Direct
# ---------------------------------------------------------------------------
function Get-GuestCredential {
    if ([string]::IsNullOrEmpty($CredentialScript)) {
        throw '-CredentialScript is required: point it at the .ps1 that defines your credential function'
    }
    if (-not (Test-Path -LiteralPath $CredentialScript)) {
        throw ('credential script not found: ' + $CredentialScript)
    }
    . $CredentialScript
    $command = Get-Command $CredentialFunction -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw ('function ' + $CredentialFunction + ' is not defined by ' + $CredentialScript)
    }
    $splat = @{}
    if ($command.Parameters.ContainsKey('User')) {
        if ([string]::IsNullOrEmpty($CredentialUser)) {
            throw ('function ' + $CredentialFunction + ' takes -User; pass -CredentialUser')
        }
        $splat['User'] = $CredentialUser
    }
    $cred = & $CredentialFunction @splat
    if ($null -eq $cred -or -not ($cred -is [System.Management.Automation.PSCredential])) {
        throw ('function ' + $CredentialFunction + ' did not return a PSCredential')
    }
    return $cred
}

function Connect-GuestSession {
    param([int]$TimeoutMinutes = 8, [int]$PollSeconds = 10)
    $cred = Get-GuestCredential
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastError = ''
    while ((Get-Date) -lt $deadline) {
        $session = $null
        try {
            $session = New-PSSession -VMName $VmName -Credential $cred -ErrorAction Stop
            Write-RunLog ('[direct] PowerShell Direct session up on ' + $VmName)
            return $session
        } catch {
            $lastError = $_.Exception.Message
            if ($null -ne $session) { try { Remove-PSSession -Session $session -ErrorAction SilentlyContinue } catch { } }
            Write-RunLog ('[direct] waiting: ' + $lastError)
            Start-Sleep -Seconds $PollSeconds
        }
    }
    throw ('PowerShell Direct did not come up on ' + $VmName + ' within ' + $TimeoutMinutes + ' minutes: ' + $lastError)
}

function Send-GuestFile {
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)][string]$GuestPath
    )
    $guestDir = Split-Path -Parent $GuestPath
    if (-not [string]::IsNullOrEmpty($guestDir)) {
        $null = Invoke-Command -Session $Session -ArgumentList $guestDir -ScriptBlock {
            param($d)
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        }
    }
    Copy-Item -LiteralPath $LocalPath -Destination $GuestPath -ToSession $Session -Force
}

function Receive-GuestFile {
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$GuestPath,
        [Parameter(Mandatory = $true)][string]$LocalPath
    )
    $localDir = Split-Path -Parent $LocalPath
    if (-not [string]::IsNullOrEmpty($localDir) -and -not (Test-Path -LiteralPath $localDir)) {
        New-Item -ItemType Directory -Force -Path $localDir | Out-Null
    }
    Copy-Item -Path $GuestPath -Destination $LocalPath -FromSession $Session -Force
}

function Get-GuestFingerprint {
    param([Parameter(Mandatory = $true)]$Session)
    return Invoke-Command -Session $Session -ScriptBlock {
        $info = [ordered]@{
            computerName   = [string]$env:COMPUTERNAME
            userName       = [string]$env:USERNAME
            userProfile    = [string]$env:USERPROFILE
            profileIsAscii = ($env:USERPROFILE -match '^[\x20-\x7E]+$')
            psVersion      = $PSVersionTable.PSVersion.ToString()
            osCaption      = ''
            osVersion      = ''
            executionPolicy = ''
            node           = ''
            npm            = ''
            git            = ''
            winget         = ''
            proxyEnv       = ''
        }
        try { $os = Get-CimInstance -ClassName Win32_OperatingSystem; $info.osCaption = [string]$os.Caption; $info.osVersion = [string]$os.Version } catch { }
        try { $info.executionPolicy = [string](Get-ExecutionPolicy -Scope CurrentUser) } catch { }
        foreach ($pair in @(@('node', 'node'), @('npm', 'npm'), @('git', 'git'), @('winget', 'winget'))) {
            $found = Get-Command $pair[1] -ErrorAction SilentlyContinue
            if ($null -ne $found) {
                $value = ''
                try { $value = (& $found.Source --version 2>&1 | Out-String).Trim() } catch { $value = 'present, version failed' }
                $info[$pair[0]] = [string]$found.Source + ' ' + $value
            }
        }
        $info.proxyEnv = [string][Environment]::GetEnvironmentVariable('HTTP_PROXY', 'Machine')
        return [pscustomobject]$info
    }
}

# ---------------------------------------------------------------------------
# bridge primitives
# ---------------------------------------------------------------------------
function Get-PortProxyEntries {
    $text = ''
    try { $text = ((netsh interface portproxy show v4tov4 2>&1) | Out-String) } catch { $text = '' }
    $entries = @()
    foreach ($line in ($text -split "\r?\n")) {
        $m = [regex]::Match($line, '^\s*(\d+\.\d+\.\d+\.\d+)\s+(\d+)\s+(\d+\.\d+\.\d+\.\d+)\s+(\d+)\s*$')
        if ($m.Success) {
            $entries += [pscustomobject]@{
                listenAddress  = $m.Groups[1].Value
                listenPort     = [int]$m.Groups[2].Value
                connectAddress = $m.Groups[3].Value
                connectPort    = [int]$m.Groups[4].Value
            }
        }
    }
    return $entries
}

function Get-SwitchAddress {
    $addr = Get-NetIPAddress -InterfaceAlias $SwitchAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $addr) { throw ('no IPv4 address on ' + $SwitchAlias + '; is the switch up?') }
    return @{ ip = [string]$addr.IPAddress; prefix = [int]$addr.PrefixLength }
}

function Get-NetworkCidr {
    param([string]$Ip, [int]$Prefix)
    $bytes = [Net.IPAddress]::Parse($Ip).GetAddressBytes()
    $value = [int64]$bytes[0] * 16777216 + [int64]$bytes[1] * 65536 + [int64]$bytes[2] * 256 + [int64]$bytes[3]
    $hostBits = 32 - $Prefix
    $mask = [int64](4294967295 - ([math]::Pow(2, $hostBits) - 1))
    $net = $value -band $mask
    $v = $net -band 4294967295
    $o1 = [int](($v -shr 24) -band 255)
    $o2 = [int](($v -shr 16) -band 255)
    $o3 = [int](($v -shr 8) -band 255)
    $o4 = [int]($v -band 255)
    return (([string]$o1) + '.' + [string]$o2 + '.' + [string]$o3 + '.' + [string]$o4 + '/' + [string]$Prefix)
}

function Test-Tcp {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 3000)
    $client = $null
    try {
        $client = New-Object Net.Sockets.TcpClient
        $ok = $client.ConnectAsync($TargetHost, $Port).Wait($TimeoutMs) -and $client.Connected
        return @{ ok = [bool]$ok; error = '' }
    } catch {
        $msg = $_.Exception.Message
        if ($null -ne $_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        return @{ ok = $false; error = $msg }
    } finally {
        if ($null -ne $client) { $client.Close() }
    }
}

function Remove-OwnPortProxy {
    param([string[]]$Addresses)
    $removed = @()
    foreach ($a in $Addresses) {
        if ([string]::IsNullOrEmpty($a)) { continue }
        if ($a -eq '0.0.0.0') { continue }
        $out = (netsh interface portproxy delete v4tov4 ("listenaddress=" + $a) ("listenport=" + $ProxyPort) 2>&1 | Out-String)
        $removed += [ordered]@{ listenAddress = $a; output = ([string]$out).Trim() }
        Write-RunLog ('[unbridge] delete portproxy ' + $a + ':' + $ProxyPort + ' -> "' + ([string]$out).Trim() + '"')
    }
    return $removed
}

function Set-GuestProxyBridge {
    param([Parameter(Mandatory = $true)]$Session, [Parameter(Mandatory = $true)][string]$ProxyUrl)
    return Invoke-Command -Session $Session -ArgumentList $ProxyUrl -ScriptBlock {
        param($url)
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        Set-ItemProperty -Path $key -Name ProxyEnable -Value 1 -Type DWord
        Set-ItemProperty -Path $key -Name ProxyServer -Value $url -Type String
        Set-ItemProperty -Path $key -Name ProxyOverride -Value '<local>' -Type String
        foreach ($scope in @('Machine', 'User')) {
            [Environment]::SetEnvironmentVariable('HTTP_PROXY', $url, $scope)
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $url, $scope)
            [Environment]::SetEnvironmentVariable('NO_PROXY', 'localhost,127.0.0.1', $scope)
        }
        return [pscustomobject]@{
            proxyEnable = (Get-ItemProperty -Path $key).ProxyEnable
            proxyServer = [string](Get-ItemProperty -Path $key).ProxyServer
            machineHttp = [string][Environment]::GetEnvironmentVariable('HTTP_PROXY', 'Machine')
            userHttp    = [string][Environment]::GetEnvironmentVariable('HTTP_PROXY', 'User')
        }
    }
}

function Clear-GuestProxyBridge {
    param([Parameter(Mandatory = $true)]$Session)
    return Invoke-Command -Session $Session -ScriptBlock {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        Set-ItemProperty -Path $key -Name ProxyEnable -Value 0 -Type DWord
        Remove-ItemProperty -Path $key -Name ProxyServer -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $key -Name ProxyOverride -ErrorAction SilentlyContinue
        foreach ($scope in @('Machine', 'User')) {
            [Environment]::SetEnvironmentVariable('HTTP_PROXY', $null, $scope)
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $null, $scope)
            [Environment]::SetEnvironmentVariable('NO_PROXY', $null, $scope)
        }
        return [pscustomobject]@{
            proxyEnable = (Get-ItemProperty -Path $key).ProxyEnable
            machineHttp = [string][Environment]::GetEnvironmentVariable('HTTP_PROXY', 'Machine')
        }
    }
}

function Invoke-Unbridge {
    $state = Read-RunJson -Name 'bridge-state.json'
    if ($null -eq $state -or -not $state.ownsBridge) {
        Write-RunLog '[unbridge] no bridge owned by this run'
        return
    }
    if ($state.vmName -ne $VmName -or $state.port -ne $ProxyPort -or $state.ruleName -ne $RuleName) {
        throw 'bridge state does not match VM/port/rule parameters; refusing to remove unrelated rules'
    }
    $owned = { $_.listenPort -eq $state.port -and $_.listenAddress -eq $state.listenAddress }
    $entries = @(Get-PortProxyEntries | Where-Object $owned)
    $deleted = @()
    if ($entries.Count -gt 0) { $deleted = @(Remove-OwnPortProxy -Addresses @($state.listenAddress)) }
    $rules = @(Get-NetFirewallRule -Name $state.ruleName -ErrorAction SilentlyContinue)
    foreach ($rule in $rules) { Remove-NetFirewallRule -Name $rule.Name -ErrorAction Stop }
    $leftEntries = @(Get-PortProxyEntries | Where-Object $owned)
    $leftRules = @(Get-NetFirewallRule -Name $state.ruleName -ErrorAction SilentlyContinue)
    $guestCleared = $null
    $session = $null
    try {
        if ((Get-VmStateName -Name $VmName) -eq 'Running') {
            $session = Connect-GuestSession -TimeoutMinutes 1
            $guestCleared = Clear-GuestProxyBridge -Session $session
        }
    } catch {
        Write-RunLog ('[unbridge] guest proxy not cleared; restore the return checkpoint: ' + $_.Exception.Message)
    } finally {
        if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    }
    $report = [ordered]@{
        deleted = $deleted
        rulesRemoved = $rules.Count
        entriesLeft = $leftEntries.Count
        rulesLeft = $leftRules.Count
        guestProxyCleared = $guestCleared
        ok = ($leftEntries.Count -eq 0 -and $leftRules.Count -eq 0)
    }
    Write-RunJson -Name 'unbridge.json' -Object $report
    if (-not $report.ok) { throw 'cleanup incomplete: owned portproxy or firewall rule remains' }
    $state.ownsBridge = $false
    Write-RunJson -Name 'bridge-state.json' -Object $state
}

# ---------------------------------------------------------------------------
# payload manifest helpers
# ---------------------------------------------------------------------------
function Get-PayloadManifest {
    param([Parameter(Mandatory = $true)][string]$Root)
    $rootFull = (Resolve-Path -LiteralPath $Root).ProviderPath
    $lines = New-Object System.Collections.ArrayList
    $files = Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force | Where-Object {
        $relative = $_.FullName.Substring($rootFull.Length).TrimStart('\', '/')
        $parts = $relative -split '[\\/]'
        # tests/results holds local evidence, never part of the payload.
        -not ($parts -contains '.git') -and -not ($parts -contains 'node_modules') -and
        -not ($relative -match '^tests[\\/]results') -and -not ($relative -match '^tests[\\/]runs')
    }
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        [void]$lines.Add($relative + '|' + [string]$file.Length + '|' + $hash)
    }
    $sorted = @($lines | Sort-Object)
    return $sorted
}

# ---------------------------------------------------------------------------
# actions
# ---------------------------------------------------------------------------
$script:ExitCode = 1
try {
$script:Result.runDir = Resolve-RunDirectory
Write-RunLog ('[start] action=' + $Action + ' vm=' + $VmName + ' runDir=' + $script:Result.runDir)

try {
    $script:Result.vmStateBefore = Get-VmStateName -Name $VmName
    $script:Result.checkpointsBefore = Get-CheckpointNames -Name $VmName
    Write-RunLog ('[state] ' + $VmName + ' is ' + $script:Result.vmStateBefore)
} catch {
    Stop-WithExit -Code 2 -Message ('cannot read VM ' + $VmName + ': ' + $_.Exception.Message)
}

if ($Action -eq 'protect') {
    if ([string]::IsNullOrEmpty($Checkpoint)) { $Checkpoint = 'akis-pre-' + $script:Stamp }
    $existing = @($script:Result.checkpointsBefore | Where-Object { $_.name -eq $Checkpoint })
    if ($existing.Count -gt 0) { Stop-WithExit -Code 2 -Message ('checkpoint already exists: ' + $Checkpoint) }
    try {
        Checkpoint-VM -Name $VmName -SnapshotName $Checkpoint -Confirm:$false | Out-Null
    } catch {
        Stop-WithExit -Code 1 -Message ('Checkpoint-VM failed: ' + $_.Exception.Message)
    }
    $script:Result.checkpoint = $Checkpoint
    # Checkpoint-VM returns before the new checkpoint shows up in Get-VMCheckpoint on this
    # host, so poll instead of failing on the first read (seen on a cold Off VM).
    $deadline = (Get-Date).AddSeconds(60)
    $created = @()
    do {
        Start-Sleep -Seconds 2
        $script:Result.checkpointsAfter = Get-CheckpointNames -Name $VmName
        $created = @($script:Result.checkpointsAfter | Where-Object { $_.name -eq $Checkpoint })
    } while ($created.Count -ne 1 -and (Get-Date) -lt $deadline)
    if ($created.Count -ne 1) { Stop-WithExit -Code 1 -Message ('checkpoint ' + $Checkpoint + ' was not created within 60s') }
    Write-RunLog ('[protect] created ' + $Checkpoint + ' (kept; deleting it is the operator decision)')
    Stop-WithExit -Code 0
}

if ($Action -eq 'restore') {
    if ([string]::IsNullOrEmpty($Checkpoint)) { Stop-WithExit -Code 2 -Message '-Checkpoint is required for -Action restore' }
    $match = @($script:Result.checkpointsBefore | Where-Object { $_.name -eq $Checkpoint })
    if ($match.Count -ne 1) { Stop-WithExit -Code 2 -Message ('checkpoint not found: ' + $Checkpoint) }
    if ($script:Result.vmStateBefore -ne 'Off') {
        Stop-WithExit -Code 2 -Message ('restore requires the VM to be Off, it is ' + $script:Result.vmStateBefore)
    }
    try {
        Restore-VMCheckpoint -VMName $VmName -Name $Checkpoint -Confirm:$false | Out-Null
    } catch {
        Stop-WithExit -Code 1 -Message ('Restore-VMCheckpoint failed: ' + $_.Exception.Message)
    }
    $script:Result.checkpointsAfter = Get-CheckpointNames -Name $VmName
    Write-RunLog ('[restore] restored ' + $Checkpoint + '; no disk was copied')
    Stop-WithExit -Code 0
}

if ($Action -eq 'start') {
    if ($script:Result.vmStateBefore -eq 'Off') {
        try { Start-VM -Name $VmName -ErrorAction Stop | Out-Null }
        catch { Stop-WithExit -Code 1 -Message ('Start-VM failed: ' + $_.Exception.Message) }
    } elseif ($script:Result.vmStateBefore -ne 'Running') {
        Stop-WithExit -Code 2 -Message ('cannot start from state ' + $script:Result.vmStateBefore)
    } else {
        Write-RunLog '[start] already running'
    }
    $session = $null
    try {
        $session = Connect-GuestSession -TimeoutMinutes $DirectTimeoutMinutes
        $script:Result.guest = Get-GuestFingerprint -Session $session
        Write-RunLog ('[start] guest ' + $script:Result.guest.computerName + ' profileIsAscii=' + $script:Result.guest.profileIsAscii + ' ps=' + $script:Result.guest.psVersion)
    } catch {
        Stop-WithExit -Code 3 -Message ('PowerShell Direct never answered: ' + $_.Exception.Message)
    } finally {
        if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    }
    Stop-WithExit -Code 0
}

if ($Action -eq 'bridge') {
    if ($NoProxy) {
        Write-RunLog '[bridge] -NoProxy: nothing created'
        $script:Result.skipped = $true
        Stop-WithExit -Code 0
    }
    $state = [ordered]@{
        vmName           = $VmName
        ruleName         = $RuleName
        ownsBridge       = $false
        timestamp        = (Get-Date).ToString('s')
        listenAddress    = ''
        prefixLength     = 0
        remoteAddress    = ''
        port             = $ProxyPort
        connectTarget    = '127.0.0.1:' + [string]$UpstreamPort
        upstreamTcp      = $null
        endToEnd         = ''
        endToEndOk       = $false
        guestProxy       = $null
        guestProbe       = $null
        ok               = $false
        error            = ''
    }
    $session = $null
    try {
        $tcp = Test-Tcp -TargetHost '127.0.0.1' -Port $UpstreamPort
        $state.upstreamTcp = [bool]$tcp.ok
        if (-not $tcp.ok) { throw ('nothing is listening on 127.0.0.1:' + $UpstreamPort + ' (' + $tcp.error + '); no bridge was created') }
        $switch = Get-SwitchAddress
        $state.listenAddress = $switch.ip
        $state.prefixLength = $switch.prefix
        $state.remoteAddress = Get-NetworkCidr -Ip $switch.ip -Prefix $switch.prefix
        Write-RunLog ('[bridge] ' + $SwitchAlias + ' = ' + $switch.ip + '/' + $switch.prefix)

        $stale = @(Get-PortProxyEntries | Where-Object { $_.listenPort -eq $ProxyPort -and ($_.listenAddress -eq $switch.ip -or $_.listenAddress -eq '0.0.0.0') })
        $staleRules = @(Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue)
        if ($stale.Count -gt 0 -or $staleRules.Count -gt 0) { throw 'bridge address/port or rule already exists; unbridge its owning run first' }
        $state.ownsBridge = $true
        Write-RunJson -Name 'bridge-state.json' -Object $state

        $addOut = (netsh interface portproxy add v4tov4 ('listenaddress=' + $switch.ip) ('listenport=' + $ProxyPort) 'connectaddress=127.0.0.1' ('connectport=' + $UpstreamPort) 2>&1 | Out-String)
        $state.portProxyAddOutput = ([string]$addOut).Trim()
        $now = @(Get-PortProxyEntries | Where-Object { $_.listenPort -eq $ProxyPort -and $_.listenAddress -eq $switch.ip })
        if ($now.Count -eq 0) { throw ('netsh portproxy add produced no entry: ' + $state.portProxyAddOutput) }
        Write-RunLog ('[bridge] portproxy ' + $switch.ip + ':' + $ProxyPort + ' -> 127.0.0.1:' + $UpstreamPort)

        $rule = New-NetFirewallRule -Name $RuleName -DisplayName $RuleName -Description 'temporary test bridge; created and removed by tests/windows/run.ps1' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $ProxyPort -LocalAddress $switch.ip -RemoteAddress $state.remoteAddress -InterfaceAlias $SwitchAlias -Profile Any -ErrorAction Stop
        Write-RunLog ('[bridge] firewall rule ' + $RuleName + ' (' + [string]$rule.Name + ')')

        Start-Sleep -Seconds 2
        $url = 'http://' + $switch.ip + ':' + [string]$ProxyPort
        try {
            $webProxy = New-Object Net.WebProxy -ArgumentList $url, $true
            $request = [Net.HttpWebRequest]::Create('https://registry.npmjs.org/')
            $request.Proxy = $webProxy
            $request.Method = 'HEAD'
            $request.Timeout = 20000
            $response = $request.GetResponse()
            $state.endToEnd = 'HTTP ' + [string][int]$response.StatusCode
            $state.endToEndOk = $true
            $response.Close()
        } catch {
            $state.endToEnd = 'FAIL ' + (($_.Exception.Message -split [Environment]::NewLine)[0])
            $state.endToEndOk = $false
        }
        Write-RunLog ('[bridge] host -> registry.npmjs.org via ' + $url + ': ' + $state.endToEnd)
        if (-not $state.endToEndOk) { throw ('bridge works at socket level but not end to end: ' + $state.endToEnd) }

        $session = Connect-GuestSession -TimeoutMinutes $DirectTimeoutMinutes
        $state.guestProxy = Set-GuestProxyBridge -Session $session -ProxyUrl $url
        Write-RunLog ('[bridge] guest system proxy ' + $state.guestProxy.proxyServer + ' enable=' + $state.guestProxy.proxyEnable)
        $probe = Invoke-Command -Session $session -ArgumentList $url, $switch.ip, $ProxyPort -ScriptBlock {
            param($proxyUrl, $ip, $port)
            $res = [ordered]@{ tcp = $false; tcpError = ''; http = ''; httpOk = $false }
            $client = $null
            try {
                $client = New-Object Net.Sockets.TcpClient
                $res.tcp = $client.ConnectAsync($ip, $port).Wait(4000) -and $client.Connected
            } catch {
                $res.tcpError = $_.Exception.Message
            } finally {
                if ($null -ne $client) { $client.Close() }
            }
            try {
                $r = Invoke-WebRequest -Uri 'https://registry.npmjs.org/' -Method Head -Proxy $proxyUrl -UseBasicParsing -TimeoutSec 25
                $res.http = 'HTTP ' + [string][int]$r.StatusCode
                $res.httpOk = $true
            } catch {
                $res.http = 'FAIL ' + (($_.Exception.Message -split [Environment]::NewLine)[0])
            }
            return [pscustomobject]$res
        }
        $state.guestProbe = $probe
        Write-RunLog ('[bridge] guest TCP=' + $probe.tcp + ' http=' + $probe.http)
        if (-not $probe.httpOk) { throw ('the guest cannot reach the registry through the bridge: ' + $probe.http) }
        $state.ok = $true
    } catch {
        $state.error = $_.Exception.Message
        Write-RunLog ('[bridge][error] ' + $state.error)
    } finally {
        if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    }
    $script:Result.bridge = $state
    Write-RunJson -Name 'bridge.json' -Object $state
    if ($state.ok) { Stop-WithExit -Code 0 }
    Stop-WithExit -Code 5 -Message ('bridge failed: ' + $state.error)
}

if ($Action -eq 'copy') {
    if ([string]::IsNullOrEmpty($Payload)) { Stop-WithExit -Code 2 -Message '-Payload is required for -Action copy' }
    if (-not (Test-Path -LiteralPath $Payload -PathType Container)) { Stop-WithExit -Code 2 -Message ('payload is not a directory: ' + $Payload) }
    $archive = Join-Path $script:Result.runDir 'payload.zip'
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    $hostManifest = @(Get-PayloadManifest -Root $Payload)
    if ($hostManifest.Count -eq 0) { Stop-WithExit -Code 2 -Message ('payload directory is empty: ' + $Payload) }
    # Compress-Archive omits dotfiles on 5.1 and would include nested node_modules.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($archive, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($line in $hostManifest) {
            $relative = ($line -split '\|', 3)[0]
            $source = Join-Path $Payload $relative
            $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $source, $relative)
        }
    } finally { $zip.Dispose() }
    Write-RunLog ('[copy] archive ' + (Split-Path -Leaf $archive) + ' holds ' + $hostManifest.Count + ' files')

    $session = $null
    try {
        $session = Connect-GuestSession -TimeoutMinutes $DirectTimeoutMinutes
        Send-GuestFile -Session $session -LocalPath $archive -GuestPath ($GuestPayloadDir + '.zip')
        $guestManifest = Invoke-Command -Session $session -ArgumentList $GuestPayloadDir -ScriptBlock {
            param($dir)
            $zip = $dir + '.zip'
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
            $rootFull = (Resolve-Path -LiteralPath $dir).ProviderPath
            $lines = New-Object System.Collections.ArrayList
            $files = Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force
            foreach ($f in $files) {
                $relative = $f.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
                $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                [void]$lines.Add($relative + '|' + [string]$f.Length + '|' + $hash)
            }
            return (@($lines | Sort-Object) -join [Environment]::NewLine)
        }
        $guestLines = @(($guestManifest -split [Environment]::NewLine) | Where-Object { -not [string]::IsNullOrEmpty($_) })
        $hostLines = @($hostManifest)
        $onlyHost = @($hostLines | Where-Object { $guestLines -notcontains $_ })
        $onlyGuest = @($guestLines | Where-Object { $hostLines -notcontains $_ })
        $report = [ordered]@{
            timestamp    = (Get-Date).ToString('s')
            payload      = $Payload
            guestDir     = $GuestPayloadDir
            hostFiles    = $hostLines.Count
            guestFiles   = $guestLines.Count
            missingInGuest = @($onlyHost | Select-Object -First 20)
            extraInGuest   = @($onlyGuest | Select-Object -First 20)
            ok           = ($onlyHost.Count -eq 0 -and $onlyGuest.Count -eq 0 -and $hostLines.Count -gt 0)
        }
        Write-RunJson -Name 'copy.json' -Object $report
        Write-RunLog ('[copy] host=' + $report.hostFiles + ' guest=' + $report.guestFiles + ' ok=' + $report.ok)
        if (-not $report.ok) { Stop-WithExit -Code 3 -Message 'payload manifest mismatch between host and guest' }
    } catch {
        Stop-WithExit -Code 3 -Message ('copy failed: ' + $_.Exception.Message)
    } finally {
        if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    }
    Stop-WithExit -Code 0
}

if ($Action -eq 'exec') {
    $session = $null
    $job = $null
    try {
        $session = Connect-GuestSession -TimeoutMinutes $DirectTimeoutMinutes
        $guestScriptPath = $GuestPayloadDir + '\' + $GuestScript
        $exists = Invoke-Command -Session $session -ArgumentList $guestScriptPath -ScriptBlock { param($p) return (Test-Path -LiteralPath $p) }
        if (-not $exists) { Stop-WithExit -Code 2 -Message ('guest script not found: ' + $guestScriptPath + ' (run -Action copy first)') }

        $splat = [ordered]@{
            Step       = $GuestStep
            RepoDir    = $GuestPayloadDir
            OutDir     = $GuestOutDir
            Modules    = $GuestModules
            CommitterName = $GuestCommitterName
            CommitterEmail = $GuestCommitterEmail
            StubPort   = [string]$GuestStubPort
        }
        # Empty means guest-deploy keeps its own default (<home>\.pi\agent).
        if (-not [string]::IsNullOrEmpty($GuestAgentDir)) { $splat['AgentDir'] = $GuestAgentDir }
        if ($SkipKnowledge) { $splat['SkipKnowledge'] = '1' }
        $payloadInfo = @{ path = $guestScriptPath; map = $splat }

        $job = Invoke-Command -Session $session -ArgumentList $payloadInfo -AsJob -ScriptBlock {
            param($p)
            $path = [string]$p.path
            $splat = @{}
            foreach ($key in @($p.map.Keys)) { $splat[[string]$key] = [string]$p.map[$key] }
            $all = New-Object System.Collections.ArrayList
            $code = 1
            try {
                Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
                # *>&1 also collects the guest script's information stream (its progress
                # lines go to Write-Host so they never pollute the values it returns).
                $out = & $path @splat *>&1
                foreach ($line in @($out)) { [void]$all.Add([string]$line) }
                for ($i = @($all).Count - 1; $i -ge 0; $i--) {
                    $m = [regex]::Match([string]$all[$i], '^RESULT=(\d+)$')
                    if ($m.Success) { $code = [int]$m.Groups[1].Value; break }
                }
            } catch {
                $code = 1
                [void]$all.Add('EXCEPTION: ' + $_.Exception.Message)
                [void]$all.Add(($_.ScriptStackTrace | Out-String))
            }
            return [pscustomobject]@{ exit = $code; text = (@($all) -join [Environment]::NewLine) }
        }

        $deadline = [int]($ActionTimeoutMinutes * 60)
        $null = $job | Wait-Job -Timeout $deadline
        $timedOut = ($job.State -ne 'Completed')
        # Not $result: variable names are case-insensitive, so $result is $Result is
        # $script:Result and would overwrite the action report mid-run.
        $jobResult = $null
        if (-not $timedOut) { $jobResult = @($job | Receive-Job) | Select-Object -Last 1 }
        $text = ''
        $exit = 1
        if ($null -ne $jobResult) { $text = [string]$jobResult.text; $exit = [int]$jobResult.exit }
        $evidence = Join-Path $script:Result.runDir ('guest-' + $GuestStep + '.txt')
        [IO.File]::WriteAllText($evidence, $text, $script:Utf8NoBom)
        Write-RunLog ('[exec] step=' + $GuestStep + ' exit=' + $exit + ' timedOut=' + $timedOut + ' evidence=' + (Split-Path -Leaf $evidence))

        if ($timedOut) {
            try { $job | Stop-Job -ErrorAction SilentlyContinue } catch { }
            Write-RunJson -Name 'exec.json' -Object ([ordered]@{ step = $GuestStep; timedOut = $true; deadlineMinutes = $ActionTimeoutMinutes; evidence = $evidence; note = 'the guest process may still be running; run -Action stop' })
            Stop-WithExit -Code 4 -Message ('guest step ' + $GuestStep + ' exceeded ' + $ActionTimeoutMinutes + ' minutes')
        }
        Write-RunJson -Name 'exec.json' -Object ([ordered]@{ step = $GuestStep; exit = $exit; timedOut = $false; evidence = $evidence })
        if ($exit -ne 0) { Stop-WithExit -Code 3 -Message ('guest step ' + $GuestStep + ' exited ' + $exit) }
    } catch {
        Stop-WithExit -Code 3 -Message ('exec failed: ' + $_.Exception.Message)
    } finally {
        if ($null -ne $job) { try { Remove-Job -Job $job -ErrorAction SilentlyContinue } catch { } }
        if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    }
    Stop-WithExit -Code 0
}

if ($Action -eq 'collect') {
    $session = $null
    $mirrored = @()
    try {
        $session = Connect-GuestSession -TimeoutMinutes $DirectTimeoutMinutes
        $guestFiles = Invoke-Command -Session $session -ArgumentList $GuestOutDir -ScriptBlock {
            param($dir)
            if (-not (Test-Path -LiteralPath $dir)) { return @() }
            return @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force | Where-Object { $_.Extension -in @('.json', '.jsonl', '.log', '.txt') } | ForEach-Object { $_.FullName.Substring((Resolve-Path -LiteralPath $dir).ProviderPath.Length).TrimStart('\', '/') })
        }
        foreach ($relative in @($guestFiles)) {
            $local = Join-Path (Join-Path $script:Result.runDir 'guest') ($relative.Replace('\', '/').Replace('/', '\'))
            $localDir = Split-Path -Parent $local
            if (-not (Test-Path -LiteralPath $localDir)) { New-Item -ItemType Directory -Force -Path $localDir | Out-Null }
            Receive-GuestFile -Session $session -GuestPath ($GuestOutDir + '\' + $relative) -LocalPath $local
            $mirrored += $relative
        }
        Write-RunLog ('[collect] mirrored ' + $mirrored.Count + ' file(s) from ' + $GuestOutDir)
    } catch {
        Write-RunLog ('[collect][error] ' + $_.Exception.Message)
        Write-RunJson -Name 'collect.json' -Object ([ordered]@{ ok = $false; error = $_.Exception.Message; mirrored = @() })
        Stop-WithExit -Code 3 -Message ('collect failed: ' + $_.Exception.Message)
    } finally {
        if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    }
    Write-RunJson -Name 'collect.json' -Object ([ordered]@{ ok = $true; mirrored = $mirrored })

    if (-not $KeepRunning) {
        try {
            $session = Connect-GuestSession -TimeoutMinutes 3
            $null = Invoke-Command -Session $session -ScriptBlock { shutdown.exe /s /t 5 /f }
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            $deadline = (Get-Date).AddMinutes($ShutdownTimeoutMinutes)
            while ((Get-Date) -lt $deadline) {
                if ((Get-VmStateName -Name $VmName) -eq 'Off') { break }
                Start-Sleep -Seconds 5
            }
            if ((Get-VmStateName -Name $VmName) -ne 'Off') { throw 'guest did not shut down; run -Action stop before restore' }
            Write-RunLog '[collect] guest state Off'
        } catch {
            Stop-WithExit -Code 1 -Message ('shutdown: ' + $_.Exception.Message)
        }
        try { Invoke-Unbridge }
        catch {
            Write-RunLog ('[collect][error] ' + $_.Exception.Message)
            Stop-WithExit -Code 6 -Message $_.Exception.Message
        }
    } else {
        Write-RunLog '[collect] -KeepRunning: guest left running; bridge is removed in finally'
    }
    Stop-WithExit -Code 0
}

if ($Action -eq 'unbridge') {
    try { Invoke-Unbridge }
    catch { Stop-WithExit -Code 6 -Message $_.Exception.Message }
    Stop-WithExit -Code 0
}

if ($Action -eq 'stop') {
    $state = Get-VmStateName -Name $VmName
    if ($state -eq 'Off') {
        Write-RunLog '[stop] already Off'
        Stop-WithExit -Code 0
    }
    $forced = $false
    try {
        $session = Connect-GuestSession -TimeoutMinutes 3
        $null = Invoke-Command -Session $session -ScriptBlock { shutdown.exe /s /t 5 /f }
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    } catch {
        Write-RunLog ('[stop] guest session unavailable: ' + $_.Exception.Message)
    }
    $deadline = (Get-Date).AddMinutes($ShutdownTimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        if ((Get-VmStateName -Name $VmName) -eq 'Off') { break }
        Start-Sleep -Seconds 5
    }
    if ((Get-VmStateName -Name $VmName) -ne 'Off') {
        Write-RunLog '[stop] graceful shutdown did not finish; Stop-VM -Force'
        Stop-VM -Name $VmName -Force -ErrorAction SilentlyContinue | Out-Null
        $forced = $true
        $deadline = (Get-Date).AddMinutes(2)
        while ((Get-Date) -lt $deadline) {
            if ((Get-VmStateName -Name $VmName) -eq 'Off') { break }
            Start-Sleep -Seconds 5
        }
    }
    $finalState = Get-VmStateName -Name $VmName
    Write-RunLog ('[stop] final state ' + $finalState + ' forced=' + $forced)
    if ($finalState -ne 'Off') { Stop-WithExit -Code 1 -Message ('VM did not reach Off, it is ' + $finalState) }
    Stop-WithExit -Code 0
}

Stop-WithExit -Code 2 -Message ('unhandled action: ' + $Action)
} finally {
    # collect always tears the bridge down, even when copying evidence or shutdown fails.
    # A failed bridge/start/copy/exec also releases any bridge owned by this run.
    if ($Action -eq 'collect' -or ($script:ExitCode -ne 0 -and $Action -in @('bridge', 'start', 'copy', 'exec'))) {
        try { Invoke-Unbridge }
        catch {
            if ($script:Result.runDir) {
                $script:Result.ok = $false
                $script:Result.exitCode = 6
                $script:Result.error = 'cleanup: ' + $_.Exception.Message
                Write-RunLog ('[cleanup][error] ' + $_.Exception.Message)
                Write-RunJson -Name ($Action + '.json') -Object $script:Result
            }
            exit 6
        }
    }
}
