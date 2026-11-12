#Requires -Version 5.1
<#
  tests/windows/guest-deploy.ps1 -- run inside the test VM (Windows PowerShell 5.1 or 7).
  One -Step per call, so a single ssh call stays under roughly 12 minutes.

  Steps
    prereq     record OS/PowerShell/user, pick up the bridge proxy from the machine
               environment, set the current-user execution policy to RemoteSigned the way
               DEPLOY.md asks a user to, install Node 24.22.3 (official MSI, sha256 checked
               against nodejs.org) and Git for Windows (official release asset) when they
               are missing, then install Pi 1.5.2 with
               npm install -g --ignore-scripts @earendil-works/pi-coding-agent@1.5.2.
    render     render core,memory through the PowerShell entry of DEPLOY.md: a dry run,
               then --apply, then a second --apply to see whether anything is re-created.
               Placeholder values point at the stub provider, never at a real vendor.
    knowledge  clone pi-knowledge at the pinned base commit, apply the four patches in
               order with git am, npm ci, npm run build. -SkipKnowledge skips this and
               leaves doctor checking the explicitly selected modules.
    stub       key-free self proof: copy the rendered config into an isolated temporary
               home under %TEMP%, junction the npm package tree so packages resolve,
               write a stub models.json, start scripts/stub-provider.mjs on the loopback
               and run three pi --print commands. Checks the request bodies for the tool
               set and for resident memory injection.
    doctor     node scripts/doctor.mjs --json, parsed into counts plus the FAIL labels.
    summary    aggregate the step JSON files.

  Contract with tests/windows/run.ps1: never call exit (that would kill the PowerShell
  Direct session). Print progress lines and finish with RESULT=<0|1>. Every step writes
  <OutDir>\<step>.json plus <OutDir>\guest-deploy.log, so a timed out caller still has
  evidence of how far it got.

  ASCII only: Windows PowerShell 5.1 reads a BOM-less .ps1 as the ANSI code page.
#>
[CmdletBinding()]
param(
    [ValidateSet('all', 'prereq', 'render', 'knowledge', 'packages', 'stub', 'doctor', 'summary')]
    [string]$Step = 'all',
    [string]$RepoDir = 'C:\akis-pi-test\payload',
    [string]$OutDir = 'C:\akis-pi-test\out',
    [string]$Modules = 'core,memory',
    [int]$StubPort = 18899,
    [string]$AgentDir = '',
    [int]$SkipKnowledge = 0,
    [string]$CommitterName = '',
    [string]$CommitterEmail = '',
    [int]$StubTimeoutSeconds = 90
)

Set-StrictMode -Off

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Now = Get-Date
$script:Stamp = ('{0:d2}{1:d2}{2:d2}-{3:d2}{4:d2}{5:d2}' -f $script:Now.Year, $script:Now.Month, $script:Now.Day, $script:Now.Hour, $script:Now.Minute, $script:Now.Second)
$script:LogPath = Join-Path $OutDir 'guest-deploy.log'
$script:Failure = ''
$script:ProxyUrl = ''
$script:RepoFull = ''

function Write-GuestLog {
    <#
      Writes to <OutDir>\guest-deploy.log and to the host (information) stream.
      It must never write to the output pipeline: Invoke-Captured and every step
      function are assigned from, and a log line in the pipeline would turn the
      returned object or exit code into an array. run.ps1's exec merges all streams
      (*>&1) so these lines still land in the guest-<step>.txt evidence.
    #>
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = (Get-Date).ToString('s') + ' ' + $Message
    [IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine, $script:Utf8NoBom)
    Write-Host $line
}

function Write-StepJson {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Object
    )
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $path = Join-Path $OutDir ($Name + '.json')
    [IO.File]::WriteAllText($path, ($Object | ConvertTo-Json -Depth 10), $script:Utf8NoBom)
}

function Invoke-Captured {
    <#
      Runs one native command, records its combined output, returns exit code + text.
      Never throws: a failure is data for the step JSON.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = ''
    )
    $previous = $null
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) {
        $previous = (Get-Location).Path
        Set-Location -LiteralPath $WorkingDirectory
    }
    try {
        if ($FilePath -in @('npm', 'pi')) { $FilePath += '.cmd' }
        $command = Get-Command $FilePath -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            # A missing command must not look like success: $LASTEXITCODE would be stale.
            $code = 127
            $text = 'command not found: ' + $FilePath
        } else {
            $savedPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $raw = & $command.Source @Arguments 2>&1
                $code = $LASTEXITCODE
            } finally { $ErrorActionPreference = $savedPreference }
            if ($null -eq $code) { $code = 0 }
            $text = (@($raw) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        }
    } catch {
        $code = 1
        $text = 'EXCEPTION: ' + $_.Exception.Message
    } finally {
        if (-not [string]::IsNullOrEmpty($previous)) { Set-Location -LiteralPath $previous }
    }
    Write-GuestLog ('[' + $Label + '] exit=' + $code)
    if (-not [string]::IsNullOrEmpty($text)) { Write-GuestLog ('[' + $Label + '] ' + (($text -split [Environment]::NewLine | Select-Object -Last 12) -join ' | ')) }
    return [pscustomobject]@{ exit = $code; text = $text }
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $joined = @($machinePath, $userPath) | Where-Object { -not [string]::IsNullOrEmpty($_) }
    if ($joined.Count -gt 0) { $env:PATH = ($joined -join ';') }
    $npmBin = Join-Path $env:APPDATA 'npm'
    if ((Test-Path -LiteralPath $npmBin) -and ($env:PATH -notlike ('*' + $npmBin + '*'))) {
        $env:PATH = $env:PATH + ';' + $npmBin
    }
    $gitCmd = 'C:\Program Files\Git\cmd'
    if ((Test-Path -LiteralPath $gitCmd) -and ($env:PATH -notlike ('*' + $gitCmd + '*'))) {
        $env:PATH = $env:PATH + ';' + $gitCmd
    }
}

function Import-BridgeProxy {
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Machine')
        if ([string]::IsNullOrEmpty($value)) { $value = [Environment]::GetEnvironmentVariable($name, 'User') }
        if (-not [string]::IsNullOrEmpty($value)) {
            Set-Item -Path ('env:' + $name) -Value $value
            if ($name -eq 'HTTP_PROXY') { $script:ProxyUrl = $value }
        }
    }
    if (-not [string]::IsNullOrEmpty($script:ProxyUrl)) {
        # Node's own fetch does not read HTTP_PROXY unless told to; npm does.
        Set-Item -Path 'env:NODE_USE_ENV_PROXY' -Value '1'
        Write-GuestLog ('[proxy] inherited ' + $script:ProxyUrl)
    } else {
        Write-GuestLog '[proxy] no proxy in the machine or user environment (direct connection expected)'
    }
}

function Save-Url {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Path
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $progress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec 600
    } finally {
        $ProgressPreference = $progress
    }
}

function Get-NodeVersionText {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $node) { return '' }
    try { return ((& $node.Source --version) | Out-String).Trim() } catch { return '' }
}

function Install-Node {
    $wanted = '24.22.3'
    $file = 'node-v' + $wanted + '-x64.msi'
    $base = 'https://nodejs.org/dist/v' + $wanted
    $work = Join-Path $env:TEMP ('akis-pi-node-' + $script:Stamp)
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $msi = Join-Path $work $file
    $record = [ordered]@{ wanted = $wanted; file = $file; work = $work; sha256 = ''; expectedSha256 = ''; sumsMatch = $false; signature = ''; signer = ''; installerExit = -1; installed = '' }
    try {
        Write-GuestLog ('[node] downloading ' + $base + '/' + $file)
        Save-Url -Url ($base + '/' + $file) -Path $msi
        Save-Url -Url ($base + '/SHASUMS256.txt') -Path (Join-Path $work 'SHASUMS256.txt')
        $record.sha256 = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash.ToLowerInvariant()
        $sums = Get-Content -LiteralPath (Join-Path $work 'SHASUMS256.txt')
        foreach ($line in $sums) {
            if ($line -match ('^([0-9a-f]{64})\s+' + [regex]::Escape($file) + '$')) { $record.expectedSha256 = $Matches[1] }
        }
        $record.sumsMatch = ($record.expectedSha256 -ne '' -and $record.expectedSha256 -eq $record.sha256)
        if (-not $record.sumsMatch) { throw ('sha256 does not match SHASUMS256.txt for ' + $file) }
        $signature = Get-AuthenticodeSignature -LiteralPath $msi
        $record.signature = [string]$signature.Status
        if ($null -ne $signature.SignerCertificate) { $record.signer = [string]$signature.SignerCertificate.Subject }
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $msi, '/qn', '/norestart') -Wait -PassThru
        $record.installerExit = $process.ExitCode
        if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) { throw ('msiexec exit ' + $process.ExitCode) }
        Refresh-ProcessPath
        $record.installed = Get-NodeVersionText
        if ($record.installed -ne ('v' + $wanted)) { throw ('node still reports "' + $record.installed + '" after the MSI') }
    } catch {
        $record.error = $_.Exception.Message
        Write-GuestLog ('[node][error] ' + $record.error)
    }
    Write-StepJson -Name 'prereq-node' -Object $record
    return $record
}

function Install-Git {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $work = Join-Path $env:TEMP ('akis-pi-git-' + $script:Stamp)
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $record = [ordered]@{ release = ''; asset = ''; url = ''; sha256 = ''; size = 0; signature = ''; signer = ''; installerExit = -1; installed = '' }
    try {
        Write-GuestLog '[git] querying the latest release over TLS 1.2'
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' -UseBasicParsing -TimeoutSec 120
        $record.release = [string]$release.tag_name
        $asset = @($release.assets | Where-Object { $_.name -like '*64-bit.exe' } | Select-Object -First 1)
        if ($asset.Count -eq 0) { throw 'no 64-bit installer asset in the release' }
        $record.asset = [string]$asset[0].name
        $record.url = [string]$asset[0].browser_download_url
        $record.size = [int64]$asset[0].size
        $installer = Join-Path $work $record.asset
        Write-GuestLog ('[git] downloading ' + $record.asset)
        Save-Url -Url $record.url -Path $installer
        $record.sha256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
        $signature = Get-AuthenticodeSignature -LiteralPath $installer
        $record.signature = [string]$signature.Status
        if ($null -ne $signature.SignerCertificate) { $record.signer = [string]$signature.SignerCertificate.Subject }
        $process = Start-Process -FilePath $installer -ArgumentList @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/CLOSEAPPLICATIONS') -Wait -PassThru
        $record.installerExit = $process.ExitCode
        Refresh-ProcessPath
        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($null -eq $git) { throw 'git is still not on PATH' }
        $record.installed = ((& $git.Source --version) | Out-String).Trim()
    } catch {
        $record.error = $_.Exception.Message
        Write-GuestLog ('[git][error] ' + $record.error)
    }
    Write-StepJson -Name 'prereq-git' -Object $record
    return $record
}

function Get-MissingVCRuntime {
    foreach ($name in @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot ('System32\' + $name)))) { $name }
    }
}

function Install-VCRuntime {
    $work = Join-Path $env:TEMP ('akis-pi-vcredist-' + $script:Stamp)
    $installer = Join-Path $work 'vc_redist.x64.exe'
    $record = [ordered]@{ missingBefore = @(Get-MissingVCRuntime); missingAfter = @(); signature = ''; signer = ''; installerExit = -1; ok = $false; error = '' }
    try {
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Save-Url -Url 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -Path $installer
        $signature = Get-AuthenticodeSignature -LiteralPath $installer
        $record.signature = [string]$signature.Status
        if ($null -ne $signature.SignerCertificate) { $record.signer = [string]$signature.SignerCertificate.Subject }
        if ($signature.Status -ne 'Valid' -or $record.signer -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
            throw ('VC++ installer signature rejected: ' + $record.signature + ' / ' + $record.signer)
        }
        $process = Start-Process -FilePath $installer -ArgumentList @('/install', '/quiet', '/norestart') -Wait -PassThru
        $record.installerExit = $process.ExitCode
        Write-GuestLog ('[vcredist] exit=' + $process.ExitCode)
        if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) { throw ('vc_redist.x64.exe exit ' + $process.ExitCode) }
        $record.missingAfter = @(Get-MissingVCRuntime)
        if ($record.missingAfter.Count -gt 0) { throw ('VC++ runtime still missing: ' + ($record.missingAfter -join ', ')) }
        $record.ok = $true
    } catch {
        $record.error = $_.Exception.Message
        Write-GuestLog ('[vcredist][error] ' + $record.error)
    } finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    }
    Write-StepJson -Name 'prereq-vcredist' -Object $record
    return $record
}

function Install-Pi {
    $record = [ordered]@{ wanted = '1.5.2'; before = ''; installExit = -1; after = ''; path = ''; error = '' }
    try {
        $before = Invoke-Captured -Label 'pi-before' -FilePath 'pi' -Arguments @('--version')
        $record.before = $before.text.Trim()
        if ($record.before -ne '1.5.2') {
            $install = Invoke-Captured -Label 'pi-install' -FilePath 'npm' -Arguments @('install', '-g', '--ignore-scripts', '@earendil-works/pi-coding-agent@1.5.2')
            $record.installExit = $install.exit
            if ($install.exit -ne 0) { throw ('npm install -g exited ' + $install.exit) }
        }
        Refresh-ProcessPath
        $after = Invoke-Captured -Label 'pi-after' -FilePath 'pi' -Arguments @('--version')
        $record.after = $after.text.Trim()
        $found = Get-Command pi -ErrorAction SilentlyContinue
        if ($null -ne $found) { $record.path = [string]$found.Source }
        if ($record.after -ne '1.5.2') { throw ('pi reports "' + $record.after + '", expected 1.5.2') }
    } catch {
        $record.error = $_.Exception.Message
        Write-GuestLog ('[pi][error] ' + $record.error)
    }
    Write-StepJson -Name 'prereq-pi' -Object $record
    return $record
}

# ---------------------------------------------------------------------------
# steps
# ---------------------------------------------------------------------------
function Invoke-StepPrereq {
    $record = [ordered]@{
        timestamp      = (Get-Date).ToString('s')
        computerName   = [string]$env:COMPUTERNAME
        userName       = [string]$env:USERNAME
        userProfile    = [string]$env:USERPROFILE
        profileIsAscii = ($env:USERPROFILE -match '^[\x20-\x7E]+$')
        psVersion      = $PSVersionTable.PSVersion.ToString()
        osCaption      = ''
        osVersion      = ''
        policyBefore   = ''
        policyAfter    = ''
        proxy          = ''
        node           = ''
        npm            = ''
        git            = ''
        ok             = $false
        error          = ''
    }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $record.osCaption = [string]$os.Caption
        $record.osVersion = [string]$os.Version
    } catch {
        Write-GuestLog ('[prereq][warn] cannot read the OS caption: ' + $_.Exception.Message)
    }
    try {
        $record.policyBefore = [string](Get-ExecutionPolicy -Scope Process)
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
        $record.policyAfter = [string](Get-ExecutionPolicy)
    } catch {
        Write-GuestLog ('[prereq][warn] execution policy: ' + $_.Exception.Message)
    }
    Import-BridgeProxy
    $record.proxy = $script:ProxyUrl

    try {
        Refresh-ProcessPath
        $nodeVersion = Get-NodeVersionText
        if ($nodeVersion -ne 'v24.22.3') {
            Write-GuestLog ('[prereq] node is "' + $nodeVersion + '"; installing 24.22.3')
            $nodeRecord = Install-Node
            if (-not [string]::IsNullOrEmpty([string]$nodeRecord.error)) { throw ('node install: ' + $nodeRecord.error) }
        }
        Refresh-ProcessPath
        $record.node = Get-NodeVersionText
        $npm = Get-Command npm -ErrorAction SilentlyContinue
        if ($null -ne $npm) { $record.npm = ((& $npm.Source --version) | Out-String).Trim() } else { $record.npm = 'missing' }
        if ($record.node -ne 'v24.22.3') { throw ('node is "' + $record.node + '", expected v24.22.3') }
        if ($record.npm -eq 'missing') { throw 'npm is missing after the node install' }

        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($null -eq $git) {
            Write-GuestLog '[prereq] git is missing; installing Git for Windows'
            $gitRecord = Install-Git
            if (-not [string]::IsNullOrEmpty([string]$gitRecord.error)) { throw ('git install: ' + $gitRecord.error) }
            Refresh-ProcessPath
            $git = Get-Command git -ErrorAction SilentlyContinue
            if ($null -eq $git) { throw 'git is still missing' }
        }
        $record.git = ((& $git.Source --version) | Out-String).Trim()

        if ($Modules -match '(^|,)memory(,|$)') {
            $missing = @(Get-MissingVCRuntime)
            $record.vcRuntimeMissing = $missing
            if ($missing.Count -gt 0) {
                Write-GuestLog ('[prereq] installing VC++ 2015-2022 x64 runtime: ' + ($missing -join ', '))
                $vcRecord = Install-VCRuntime
                if (-not $vcRecord.ok) { throw ('VC++ install: ' + $vcRecord.error) }
                $record.vcRuntimeInstallerExit = $vcRecord.installerExit
            }
        }

        $piRecord = Install-Pi
        if (-not [string]::IsNullOrEmpty([string]$piRecord.error)) { throw ('pi install: ' + $piRecord.error) }
        $record.pi = $piRecord.after
        $record.piPath = $piRecord.path
        $record.ok = $true
} catch {
    $record.error = $_.Exception.Message
    $script:Failure = 'prereq: ' + $record.error
    Write-GuestLog ('[prereq][error] ' + $record.error)
}
    Write-StepJson -Name 'prereq' -Object $record
    if ($record.ok) { return 0 }
    return 1
}

function Get-RenderArgs {
    # Not $args: that name is the automatic parameter array of this function, and
    # assigning to it collapses the whole list into one space separated string, so
    # node would receive a single argument.
    param([switch]$Apply)
    # Parentheses around the first element: the comma operator binds tighter than +,
    # so an unparenthesised 'scripts' + [char] + 'render.mjs', '--home', ... would fold
    # every later element into one space separated argument.
    $nodeArgs = @(( 'scripts' + [IO.Path]::DirectorySeparatorChar + 'render.mjs' ), '--home', $HOME, '--agent-dir', $AgentDir, '--modules', $Modules, '--strict')
    if ($Apply) { $nodeArgs += '--apply' }
    $nodeArgs += @('--set', 'PROVIDER=stub', '--set', 'MODEL=stub-model', '--set', 'MODEL_EXEC=stub-model', '--set', 'MODEL_REVIEW=stub-model', '--set', 'MODEL_PLAN=stub-model', '--set', 'MODEL_HISTORIAN=stub-model', '--set', 'BRAVE_KEY_REF=$BRAVE_API_KEY', '--set', 'BOCHA_KEY_REF=$BOCHA_API_KEY')
    return $nodeArgs
}

function Invoke-StepRender {
    $record = [ordered]@{
        timestamp = (Get-Date).ToString('s')
        repo      = $script:RepoFull
        agentDir  = $AgentDir
        modules   = $Modules
        dryExit   = -1
        applyExit = -1
        rerunExit = -1
        files     = @()
        rerunCreates = 0
        ok        = $false
        error     = ''
    }
    try {
        $dry = Invoke-Captured -Label 'render-dry' -FilePath 'node' -Arguments (Get-RenderArgs) -WorkingDirectory $script:RepoFull
        $record.dryExit = $dry.exit
        if ($dry.exit -ne 0) { throw ('render dry run exited ' + $dry.exit + ': ' + ($dry.text -split [Environment]::NewLine | Select-Object -Last 3 | Out-String)) }
        if ($dry.text -notmatch 'create|unchanged|diff') { throw 'render dry run printed neither create, unchanged nor diff' }
        $apply = Invoke-Captured -Label 'render-apply' -FilePath 'node' -Arguments (Get-RenderArgs -Apply) -WorkingDirectory $script:RepoFull
        $record.applyExit = $apply.exit
        if ($apply.exit -ne 0) { throw ('render --apply exited ' + $apply.exit) }
        $rerun = Invoke-Captured -Label 'render-rerun' -FilePath 'node' -Arguments (Get-RenderArgs -Apply) -WorkingDirectory $script:RepoFull
        $record.rerunExit = $rerun.exit
        foreach ($line in ($rerun.text -split [Environment]::NewLine)) {
            if ($line -match '^\s*(create|update)\b') { $record.rerunCreates += 1 }
        }
        $expected = @(
            (Join-Path $AgentDir 'settings.json'),
            (Join-Path $AgentDir 'AGENTS.md'),
            (Join-Path $AgentDir 'APPEND_SYSTEM.md'),
            (Join-Path $AgentDir 'compact-tools.json'),
            (Join-Path $AgentDir 'extensions\rtk.ts'),
            (Join-Path $AgentDir 'extensions\subagent\config.json')
        )
        if ($Modules -match 'memory') {
            $expected += (Join-Path $AgentDir 'extensions\resident-memory.ts')
            $expected += (Join-Path $HOME '.config\cortexkit\magic-context.jsonc')
        }
        $record.files = @($expected | ForEach-Object { [ordered]@{ path = $_; exists = (Test-Path -LiteralPath $_) } })
        $missing = @($record.files | Where-Object { -not $_.exists })
        if ($missing.Count -gt 0) { throw ('rendered files missing: ' + (($missing | ForEach-Object { $_.path }) -join ', ')) }
        $agentFiles = @(Get-ChildItem -LiteralPath (Join-Path $AgentDir 'agents') -Filter '*.md' -ErrorAction SilentlyContinue)
        $record.agentFiles = $agentFiles.Count
        if ($agentFiles.Count -lt 8) { throw ('expected 8 role files, found ' + $agentFiles.Count) }
        $record.ok = $true
    } catch {
        $record.error = $_.Exception.Message
        $script:Failure = 'render: ' + $record.error
        Write-GuestLog ('[render][error] ' + $record.error)
    }
    Write-StepJson -Name 'render' -Object $record
    if ($record.ok) { return 0 }
    return 1
}

function Invoke-StepKnowledge {
    $record = [ordered]@{
        timestamp = (Get-Date).ToString('s')
        skipped   = ($SkipKnowledge -ne 0)
        path      = ''
        base      = '558e8dd'
        patches   = @()
        buildExit = -1
        distIndex = $false
        version   = ''
        ok        = $false
        error     = ''
    }
    $record.skipped = ($SkipKnowledge -ne 0 -or $Modules -notmatch '(^|,)memory(,|$)')
    if ($record.skipped) {
        Write-GuestLog '[knowledge] skipped; doctor still checks the explicitly selected modules'
        $record.ok = $true
        Write-StepJson -Name 'knowledge' -Object $record
        return 0
    }
    try {
        if (-not $CommitterName -or -not $CommitterEmail) { throw 'pass CommitterName and CommitterEmail for git am; no Git config is changed' }
        $vendor = Join-Path $HOME '.pi\vendor'
        if (-not (Test-Path -LiteralPath $vendor)) { New-Item -ItemType Directory -Force -Path $vendor | Out-Null }
        $clone = Join-Path $vendor 'pi-knowledge'
        $record.path = $clone
        if (-not (Test-Path -LiteralPath (Join-Path $clone '.git'))) {
            $cloned = Invoke-Captured -Label 'knowledge-clone' -FilePath 'git' -Arguments @('clone', 'https://github.com/nczz/pi-knowledge', $clone) -WorkingDirectory $vendor
            if ($cloned.exit -ne 0) { throw ('git clone exited ' + $cloned.exit) }
        } else {
            Write-GuestLog '[knowledge] clone already present'
        }
        $co = Invoke-Captured -Label 'knowledge-checkout' -FilePath 'git' -Arguments @('checkout', $record.base) -WorkingDirectory $clone
        if ($co.exit -ne 0) { throw ('git checkout ' + $record.base + ' exited ' + $co.exit) }
        $patchDir = Join-Path $script:RepoFull 'modules\memory\patches'
        $patches = @(Get-ChildItem -LiteralPath $patchDir -Filter '*.patch' | Sort-Object Name)
        if ($patches.Count -ne 4) { throw ('expected 4 patches in ' + $patchDir + ', found ' + $patches.Count) }
        foreach ($patch in $patches) {
            $am = Invoke-Captured -Label ('knowledge-am-' + $patch.Name) -FilePath 'git' -Arguments @('-c', ('user.name=' + $CommitterName), '-c', ('user.email=' + $CommitterEmail), 'am', $patch.FullName) -WorkingDirectory $clone
            $record.patches += [ordered]@{ name = $patch.Name; exit = $am.exit }
            if ($am.exit -ne 0) {
                $null = Invoke-Captured -Label 'knowledge-am-abort' -FilePath 'git' -Arguments @('am', '--abort') -WorkingDirectory $clone
                throw ('git am failed on ' + $patch.Name + '; base commit is wrong or a patch is missing')
            }
        }
        $install = Invoke-Captured -Label 'knowledge-npm-ci' -FilePath 'npm' -Arguments @('ci') -WorkingDirectory $clone
        if ($install.exit -ne 0) { throw ('npm ci exited ' + $install.exit + ' (on native Windows this usually means Python 3 / VS Build Tools are missing; WSL2 is the recommended path)') }
        $build = Invoke-Captured -Label 'knowledge-build' -FilePath 'npm' -Arguments @('run', 'build') -WorkingDirectory $clone
        $record.buildExit = $build.exit
        if ($build.exit -ne 0) { throw ('npm run build exited ' + $build.exit) }
        $record.distIndex = (Test-Path -LiteralPath (Join-Path $clone 'dist\index.js'))
        if (-not $record.distIndex) { throw 'dist\index.js is missing after the build' }
        $packageJson = Join-Path $clone 'package.json'
        if (Test-Path -LiteralPath $packageJson) {
            $record.version = [string](Get-Content -LiteralPath $packageJson -Raw -Encoding UTF8 | ConvertFrom-Json).version
        }
        $record.ok = $true
    } catch {
        $record.error = $_.Exception.Message
        $script:Failure = 'knowledge: ' + $record.error
        Write-GuestLog ('[knowledge][error] ' + $record.error)
    }
    Write-StepJson -Name 'knowledge' -Object $record
    if ($record.ok) { return 0 }
    return 1
}

function Invoke-StepPackages {
    $record = [ordered]@{ ok = $false; packages = @(); error = '' }
    try {
        $manifest = Get-Content -LiteralPath (Join-Path $script:RepoFull 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $selected = @($Modules -split ',')
        foreach ($component in $manifest.components) {
            if ($selected -notcontains $component.module -or $component.source -notlike 'npm:*' -or $component.id -eq 'pi') { continue }
            $install = Invoke-Captured -Label ('package-' + $component.id) -FilePath 'pi' -Arguments @('install', $component.source)
            $record.packages += [ordered]@{ source = $component.source; exit = $install.exit }
            if ($install.exit -ne 0) { throw ('pi install failed for ' + $component.id) }
        }
        if ($Modules -match '(^|,)memory(,|$)') {
            $onnx = Invoke-Captured -Label 'onnx' -FilePath 'node' -Arguments @((Join-Path $script:RepoFull 'scripts\deploy-check.mjs'), 'onnx')
            $record.onnxExit = $onnx.exit
            if ($onnx.exit -ne 0) { throw ('deploy-check onnx failed: ' + $onnx.text) }
        }
        $record.ok = $true
    } catch {
        $record.error = $_.Exception.Message
        $script:Failure = 'packages: ' + $record.error
    }
    Write-StepJson -Name 'packages' -Object $record
    if ($record.ok) { return 0 }
    return 1
}

function Copy-Tree {
    param([string]$From, [string]$To)
    if (-not (Test-Path -LiteralPath $From)) { return }
    if (-not (Test-Path -LiteralPath $To)) { New-Item -ItemType Directory -Force -Path $To | Out-Null }
    Copy-Item -Path (Join-Path $From '*') -Destination $To -Recurse -Force
}

function Invoke-StepStub {
    $record = [ordered]@{
        timestamp   = (Get-Date).ToString('s')
        agentDir    = $AgentDir
        tempHome    = ''
        tempAgent   = ''
        npmJunction = ''
        stubPort    = $StubPort
        runs        = @()
        tools       = @()
        residentMemory = $false
        ok          = $false
        error       = ''
    }
    $stubProcess = $null
    $junctionPath = ''
    try {
        $root = Join-Path $env:TEMP ('akis-pi-stub-' + $script:Stamp)
        $tempHome = Join-Path $root 'home'
        $tempAgent = Join-Path $tempHome '.pi\agent'
        New-Item -ItemType Directory -Force -Path $tempAgent | Out-Null
        $record.tempHome = $tempHome
        $record.tempAgent = $tempAgent
        $tempConfig = Join-Path $tempHome '.config'
        if ($Modules.Split(',') -contains 'memory') {
            $configRoot = $env:XDG_CONFIG_HOME
            if ([string]::IsNullOrWhiteSpace($configRoot)) { $configRoot = Join-Path $HOME '.config' }
            $mcConfig = Join-Path $configRoot 'cortexkit\magic-context.jsonc'
            if (-not (Test-Path -LiteralPath $mcConfig)) { throw 'deployed MC config missing' }
            New-Item -ItemType Directory -Force -Path (Join-Path $tempConfig 'cortexkit') | Out-Null
            Copy-Item -LiteralPath $mcConfig -Destination (Join-Path $tempConfig 'cortexkit\magic-context.jsonc')
        }

        foreach ($name in @('settings.json', 'AGENTS.md', 'APPEND_SYSTEM.md', 'compact-tools.json')) {
            $source = Join-Path $AgentDir $name
            if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $tempAgent $name) -Force }
        }
        foreach ($dir in @('agents', 'prompts', 'extensions', 'skills')) {
            Copy-Tree -From (Join-Path $AgentDir $dir) -To (Join-Path $tempAgent $dir)
        }

        # Packages stay where they were installed: a junction costs nothing and keeps the
        # isolated settings able to resolve npm entries without a second install.
        $packagesDir = Join-Path $AgentDir 'npm'
        if (Test-Path -LiteralPath $packagesDir) {
            $junctionPath = Join-Path $tempAgent 'npm'
            $linked = Invoke-Captured -Label 'stub-junction' -FilePath 'cmd.exe' -Arguments @('/c', 'mklink', '/J', $junctionPath, $packagesDir)
            $record.npmJunction = $junctionPath
            if ($linked.exit -ne 0) { throw ('mklink /J failed: ' + $linked.text) }
        } else {
            Write-GuestLog '[stub][warn] no npm package tree in the deployed agent dir; the tool set check may fail'
        }

        $models = [ordered]@{
            providers = [ordered]@{
                stub = [ordered]@{
                    baseUrl = 'http://127.0.0.1:' + [string]$StubPort + '/v1'
                    api     = 'openai-completions'
                    apiKey  = 'dummy'
                    models  = @([ordered]@{
                        id            = 'stub-model'
                        name          = 'Stub'
                        cost          = [ordered]@{ input = 0; output = 0; cacheRead = 0; cacheWrite = 0 }
                        contextWindow = 200000
                        maxTokens     = 1000
                    })
                }
            }
        }
        [IO.File]::WriteAllText((Join-Path $tempAgent 'models.json'), ($models | ConvertTo-Json -Depth 10), $script:Utf8NoBom)

        $settingsPath = Join-Path $tempAgent 'settings.json'
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $settings.defaultProvider = 'stub'
        $settings.defaultModel = 'stub-model'
        $settings.enabledModels = @('stub/stub-model')
        [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 20), $script:Utf8NoBom)

        # Only synthetic memory in the isolated home; never read the user's RESIDENT.
        $residentFile = Join-Path $tempAgent 'memory\RESIDENT.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $residentFile) | Out-Null
        [IO.File]::WriteAllText($residentFile, 'AKIS_STUB_RESIDENT_SENTINEL', $script:Utf8NoBom)

        $stubLog = Join-Path $OutDir 'stub-requests.jsonl'
        if (Test-Path -LiteralPath $stubLog) { Remove-Item -LiteralPath $stubLog -Force }
        $stubScript = Join-Path $script:RepoFull 'scripts\stub-provider.mjs'
        if (-not (Test-Path -LiteralPath $stubScript)) { throw ('stub provider missing: ' + $stubScript) }
        $node = Get-Command node -ErrorAction Stop
        $stubProcess = Start-Process -FilePath $node.Source -ArgumentList @(('"' + $stubScript + '"'), '--port', [string]$StubPort, '--log', ('"' + $stubLog + '"')) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $OutDir 'stub-stdout.txt') -RedirectStandardError (Join-Path $OutDir 'stub-stderr.txt')
        $deadline = (Get-Date).AddSeconds($StubTimeoutSeconds)
        $listening = $false
        while ((Get-Date) -lt $deadline) {
            $client = $null
            try {
                $client = New-Object Net.Sockets.TcpClient
                $listening = $client.ConnectAsync('127.0.0.1', $StubPort).Wait(1000) -and $client.Connected
            } catch {
                $listening = $false
            } finally {
                if ($null -ne $client) { $client.Close() }
            }
            if ($listening) { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $listening) { throw ('stub provider never listened on 127.0.0.1:' + $StubPort) }

        $savedEnv = @{}
        foreach ($name in @('PI_CODING_AGENT_DIR', 'USERPROFILE', 'HOME', 'PI_RESIDENT_MEMORY_FILE', 'PI_RESIDENT_MEMORY_OFF', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'MAGIC_CONTEXT_STORAGE_DIR', 'MAGIC_CONTEXT_LOG_PATH')) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        try {
            $env:PI_CODING_AGENT_DIR = $tempAgent
            $env:USERPROFILE = $tempHome
            $env:HOME = $tempHome
            $env:PI_RESIDENT_MEMORY_FILE = $residentFile
            $env:PI_RESIDENT_MEMORY_OFF = '0'
            $env:XDG_CONFIG_HOME = $tempConfig
            $env:XDG_DATA_HOME = Join-Path $tempHome '.local\share'
            $env:MAGIC_CONTEXT_STORAGE_DIR = Join-Path $env:XDG_DATA_HOME 'cortexkit\magic-context'
            $env:MAGIC_CONTEXT_LOG_PATH = Join-Path $OutDir 'stub-mc.log'
            $prompts = @(
                @('smoke', 'hi'),
                @('roles', 'delegate nothing; list the subagent roles you can use'),
                @('tools', 'answer with the number of tools you can call directly')
            )
            foreach ($item in $prompts) {
                $run = Invoke-Captured -Label ('stub-pi-' + $item[0]) -FilePath 'pi' -Arguments @('--provider', 'stub', '--model', 'stub-model', '--print', '--no-session', $item[1])
                $record.runs += [ordered]@{ name = $item[0]; exit = $run.exit; stubOk = ($run.text -match 'stub-ok'); output = $run.text.Trim() }
            }
        } finally {
            foreach ($name in @('PI_CODING_AGENT_DIR', 'USERPROFILE', 'HOME', 'PI_RESIDENT_MEMORY_FILE', 'PI_RESIDENT_MEMORY_OFF', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'MAGIC_CONTEXT_STORAGE_DIR', 'MAGIC_CONTEXT_LOG_PATH')) {
                if ($null -eq $savedEnv[$name]) { Remove-Item -Path ('env:' + $name) -ErrorAction SilentlyContinue }
                else { Set-Item -Path ('env:' + $name) -Value $savedEnv[$name] }
            }
        }

        if (Test-Path -LiteralPath $stubLog) {
            # -Encoding UTF8 is required: 5.1 otherwise decodes the log with the ANSI code
            # page, and a double byte CJK trail byte can be read as a quote or backslash,
            # which makes ConvertFrom-Json fail mid record.
            $rows = @(Get-Content -LiteralPath $stubLog -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($rows.Count -gt 0) {
                $first = $rows[0] | ConvertFrom-Json
                $names = @()
                foreach ($tool in @($first.tools)) { if ($null -ne $tool.function) { $names += [string]$tool.function.name } }
                $record.tools = $names
                $record.requestCount = $rows.Count
            }
            if ($Modules.Split(',') -contains 'memory') {
                $residentCheck = Invoke-Captured -Label 'stub-resident' -FilePath 'node' -Arguments @((Join-Path $script:RepoFull 'scripts\deploy-check.mjs'), 'stub-resident', $stubLog, 'AKIS_STUB_RESIDENT_SENTINEL')
                $record.residentMemory = ($residentCheck.exit -eq 0)
                if (-not $record.residentMemory) { throw ('resident injection check failed: ' + $residentCheck.text) }
            }
        }
        $toolCheck = Invoke-Captured -Label 'stub-tools' -FilePath 'node' -Arguments @((Join-Path $script:RepoFull 'scripts\deploy-check.mjs'), 'stub-requests', $stubLog)
        $record.toolCheckExit = $toolCheck.exit
        $failedRuns = @($record.runs | Where-Object { $_.exit -ne 0 -or -not $_.stubOk })
        if ($failedRuns.Count -gt 0) { throw ('pi runs without stub-ok: ' + (($failedRuns | ForEach-Object { $_.name }) -join ', ')) }
        if ($toolCheck.exit -ne 0) { throw ('direct tool check failed: ' + $toolCheck.text) }
        $record.ok = $true
    } catch {
        $record.error = $_.Exception.Message
        $script:Failure = 'stub: ' + $record.error
        Write-GuestLog ('[stub][error] ' + $record.error)
    } finally {
        if ($null -ne $stubProcess) {
            try { Stop-Process -Id $stubProcess.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
        # Remove the junction itself, never the package tree it points at.
        if (-not [string]::IsNullOrEmpty($junctionPath) -and (Test-Path -LiteralPath $junctionPath)) {
            try { [IO.Directory]::Delete($junctionPath, $false) } catch { Write-GuestLog ('[stub][warn] junction: ' + $_.Exception.Message) }
        }
        if (-not [string]::IsNullOrEmpty($record.tempHome)) {
            $root = Split-Path -Parent $record.tempHome
            if (Test-Path -LiteralPath $root) {
                try { Remove-Item -LiteralPath $root -Recurse -Force } catch { Write-GuestLog ('[stub][warn] temp cleanup: ' + $_.Exception.Message) }
            }
        }
    }
    Write-StepJson -Name 'stub' -Object $record
    if ($record.ok) { return 0 }
    return 1
}

function Invoke-StepDoctor {
    $record = [ordered]@{
        timestamp = (Get-Date).ToString('s')
        modules   = ''
        exit      = -1
        counts    = [ordered]@{ PASS = 0; WARN = 0; FAIL = 0 }
        fails     = @()
        warns     = @()
        raw       = ''
        ok        = $false
        error     = ''
    }
    try {
        $doctorModules = $Modules
        $distIndex = Join-Path $HOME '.pi\vendor\pi-knowledge\dist\index.js'
        # Check every selected module, even if knowledge installation failed or was skipped.
        $record.modules = $doctorModules
        $nodeArgs = @(( 'scripts' + [IO.Path]::DirectorySeparatorChar + 'doctor.mjs' ), '--home', $HOME, '--agent-dir', $AgentDir, '--modules', $doctorModules, '--json')
        $run = Invoke-Captured -Label 'doctor' -FilePath 'node' -Arguments $nodeArgs -WorkingDirectory $script:RepoFull
        $record.exit = $run.exit
        $record.raw = $run.text
        $rawPath = Join-Path $OutDir 'doctor-raw.json'
        [IO.File]::WriteAllText($rawPath, $run.text, $script:Utf8NoBom)
        $parsed = $run.text | ConvertFrom-Json
        $record.counts = [ordered]@{
            PASS = [int]$parsed.counts.PASS
            WARN = [int]$parsed.counts.WARN
            FAIL = [int]$parsed.counts.FAIL
        }
        foreach ($result in @($parsed.results)) {
            if ($result.status -eq 'FAIL') { $record.fails += ([string]$result.label + ' :: ' + [string]$result.detail) }
            if ($result.status -eq 'WARN') { $record.warns += [string]$result.label }
        }
        # A native Windows run is expected to show platform verification WARN per component.
        if ($run.exit -ne 0 -or $record.counts.FAIL -ne 0) { throw ('doctor exited ' + $run.exit + ', reports ' + $record.counts.FAIL + ' FAIL') }
        $record.ok = $true
    } catch {
        $record.error = $_.Exception.Message
        $script:Failure = 'doctor: ' + $record.error
        Write-GuestLog ('[doctor][error] ' + $record.error)
    }
    Write-StepJson -Name 'doctor' -Object $record
    if ($record.ok) { return 0 }
    return 1
}

function Invoke-StepSummary {
    $record = [ordered]@{
        timestamp = (Get-Date).ToString('s')
        steps     = [ordered]@{}
        ok        = $true
        failure   = $script:Failure
    }
    foreach ($name in @('prereq', 'render', 'knowledge', 'packages', 'stub', 'doctor')) {
        $path = Join-Path $OutDir ($name + '.json')
        if (-not (Test-Path -LiteralPath $path)) {
            $record.steps[$name] = 'not-run'
            $record.ok = $false
            continue
        }
        $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $okValue = $false
        if ($null -ne $data.ok) { $okValue = [bool]$data.ok }
        if ($data.skipped) { $record.steps[$name] = 'skipped' } else { $record.steps[$name] = [string]$okValue }
        if (-not $okValue) { $record.ok = $false }
    }
    Write-StepJson -Name 'summary' -Object $record
    if ($record.ok) { return 0 }
    return 1
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
function Invoke-StepByName {
    <#
      Runs one step function and returns its exit code. Every step function echoes its
      progress lines with Write-Output and returns 0/1 as the last output item, so the
      caller must split the two: assigning the function output directly would collect
      the log lines and the code into one array. The lines are parked in a script scope
      variable and re-emitted by the caller, which keeps $code an integer.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    $map = @{
        prereq = 'Invoke-StepPrereq'; render = 'Invoke-StepRender'; knowledge = 'Invoke-StepKnowledge'
        packages = 'Invoke-StepPackages'; stub = 'Invoke-StepStub'; doctor = 'Invoke-StepDoctor'
        summary = 'Invoke-StepSummary'
    }
    if (-not $map.ContainsKey($Name)) { throw ('unknown step: ' + $Name) }
    $items = @(& $map[$Name])
    $script:StepLines = @()
    $code = 1
    if ($items.Count -gt 0 -and $items[$items.Count - 1] -is [int]) {
        $code = [int]$items[$items.Count - 1]
        if ($items.Count -gt 1) { $script:StepLines = @($items | Select-Object -First ($items.Count - 1)) }
    } else {
        $script:StepLines = $items
    }
    return $code
}

$script:StepLines = @()
$code = 1
try {
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $script:RepoFull = (Resolve-Path -LiteralPath $RepoDir).ProviderPath
    if ([string]::IsNullOrEmpty($AgentDir)) { $AgentDir = Join-Path $HOME '.pi\agent' }
    # DEPLOY.md exports this once, then render, pi install and doctor all follow it.
    $env:PI_CODING_AGENT_DIR = $AgentDir
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH','User')
    Write-GuestLog ('[start] step=' + $Step + ' repo=' + $script:RepoFull + ' agent=' + $AgentDir + ' modules=' + $Modules)
    Write-GuestLog ('[start] ps=' + $PSVersionTable.PSVersion.ToString() + ' user=' + [string]$env:USERNAME + ' profile=' + [string]$env:USERPROFILE)

    if ($Step -eq 'all') {
        foreach ($name in @('prereq', 'render', 'knowledge', 'packages', 'stub', 'doctor', 'summary')) {
            $code = Invoke-StepByName $name
            foreach ($line in $script:StepLines) { Write-Output $line }
            if ($code -ne 0) { break }
        }
    } else {
        $code = Invoke-StepByName $Step
        foreach ($line in $script:StepLines) { Write-Output $line }
    }
} catch {
    $script:Failure = 'unhandled: ' + $_.Exception.Message
    Write-GuestLog ('[fatal] ' + $script:Failure)
    Write-GuestLog ($_.ScriptStackTrace | Out-String)
    $code = 1
}

Write-GuestLog ('[done] step=' + $Step + ' result=' + $code + ' failure=' + $script:Failure)
Write-Output ('RESULT=' + $code)
