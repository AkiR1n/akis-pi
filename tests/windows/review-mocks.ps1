#Requires -Version 5.1
# Isolated control-flow regression tests. No Hyper-V/network/Pi commands run here.
param([string]$Scratch = (Join-Path $env:TEMP ('akis-review-mocks-' + [guid]::NewGuid().ToString('N'))))
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Scratch | Out-Null
function Assert-True { param($Condition, [string]$Message) if (-not $Condition) { throw $Message } }
$root = $PSScriptRoot
foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.ps1') {
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) ($file.Name + ': ' + ($errors | Out-String))
    Write-Output ('PARSE-OK ' + $file.Name)
}
$driver = [IO.File]::ReadAllText((Join-Path $root 'run.ps1')) -replace '(?m)^#Requires.*$', ''
$mocks = @'
function Get-VmStateName { return 'Off' }
function Get-CheckpointNames { return @([pscustomobject]@{name='baseline'}) }
function Connect-GuestSession { throw 'simulated guest failure' }
function Write-RunLog { param($Message) }
function Write-RunJson { param($Name,$Object) }
function Read-RunJson {
    param($Name)
    return [pscustomobject]@{vmName='test-vm';port=17892;ruleName='test-rule';ownsBridge=$true;listenAddress='192.0.2.1'}
}
function Get-PortProxyEntries { return $script:mockEntries }
function Remove-OwnPortProxy {
    param($Addresses)
    Assert-True ($Addresses.Count -eq 1 -and $Addresses[0] -eq '192.0.2.1') 'unbridge removed an unrelated address'
    $script:mockEntries = @($script:mockEntries | Where-Object { $_.listenAddress -ne $Addresses[0] })
}
function Get-NetFirewallRule { param($Name) return $script:mockRules }
function Remove-NetFirewallRule { param($Name) Assert-True ($Name -eq 'test-rule') 'wrong firewall rule';$script:mockRules=@() }
function Stop-WithExit { param($Code,$Message) $script:ExitCode=$Code;throw ('MOCK_EXIT=' + $Code) }
function Test-Tcp { return @{ok=$false;error='simulated offline upstream'} }
'@
$payload = Join-Path $Scratch 'payload'
New-Item -ItemType Directory -Force -Path (Join-Path $payload 'node_modules') | Out-Null
[IO.File]::WriteAllText((Join-Path $payload '.gitattributes'), 'hidden file')
[IO.File]::WriteAllText((Join-Path $payload 'visible.txt'), 'visible file')
[IO.File]::WriteAllText((Join-Path $payload 'node_modules\excluded.txt'), 'excluded file')
foreach ($action in @('collect', 'exec', 'bridge', 'copy')) {
    $script:mockEntries = @([pscustomobject]@{listenAddress='192.0.2.1';listenPort=17892}, [pscustomobject]@{listenAddress='192.0.2.2';listenPort=17892})
    $script:mockRules = @([pscustomobject]@{Name='test-rule'})
    $body = $driver.Replace('$script:ExitCode = 1', $mocks + [Environment]::NewLine + '$script:ExitCode = 1')
    try { & ([scriptblock]::Create($body)) -Action $action -VmName test-vm -RunDir $Scratch -RuleName test-rule -KeepRunning -Payload $payload }
    catch { Assert-True ($_.Exception.Message -like 'MOCK_EXIT=*') ('unexpected driver error: ' + $_) }
    Assert-True ($script:mockRules.Count -eq 0) ($action + ' failed to clean firewall in finally')
    Assert-True ($script:mockEntries.Count -eq 1 -and $script:mockEntries[0].listenAddress -eq '192.0.2.2') ($action + ' failed exact bridge cleanup')
    Write-Output ('MOCK-OK ' + $action + ' failure cleans only owned bridge in finally')
}
$zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $Scratch 'payload.zip'))
try {
    $names = @($zip.Entries | ForEach-Object { $_.FullName })
    Assert-True ($names.Count -eq 2 -and $names -contains '.gitattributes' -and $names -contains 'visible.txt') 'payload lost a dotfile or included node_modules'
} finally { $zip.Dispose() }
Write-Output 'MOCK-OK payload archive includes dotfiles and excludes node_modules'

# Execute the real session try/finally with only its driver call replaced.
$session = [IO.File]::ReadAllText((Join-Path $root 'session.ps1')) -replace '(?m)^#Requires.*$', ''
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($session, [ref]$tokens, [ref]$errors)
$definition = $ast.Find({param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Invoke-Driver'}, $true)
$replacement = @'
function Invoke-Driver {
    param($Action, $Options=@{})
    $script:mockCalls.Add([pscustomobject]@{action=$Action;checkpoint=$Options.Checkpoint}) | Out-Null
    if ($Action -eq 'exec') { throw 'simulated test failure' }
    if ($Action -eq 'collect') { throw 'simulated evidence failure' }
}
'@
$session = $session.Remove($definition.Extent.StartOffset, $definition.Extent.EndOffset - $definition.Extent.StartOffset).Insert($definition.Extent.StartOffset, $replacement)
$session = $session.Replace('Join-Path $PSScriptRoot ''run.ps1''', '''mock-driver''')
$session = $session.Replace('exit 1', 'throw ''MOCK_SESSION_FAIL''').Replace('exit 0', 'return')
foreach ($scenario in @('dev', 'smoke')) {
    $script:mockCalls = New-Object System.Collections.ArrayList
    $dir = Join-Path $Scratch $scenario
    try { & ([scriptblock]::Create($session)) -Scenario $scenario -VmName test-vm -BaselineCheckpoint baseline -Payload $Scratch -CredentialScript 'unused.ps1' -RunDir $dir -NoProxy }
    catch { Assert-True ($_.Exception.Message -eq 'MOCK_SESSION_FAIL') ('unexpected session error: ' + $_) }
    $report = Get-Content -LiteralPath (Join-Path $dir 'session.json') -Raw | ConvertFrom-Json
    $calls = @($script:mockCalls)
    $tail = ($calls | Select-Object -Last 4 | ForEach-Object {$_.action}) -join ','
    Assert-True ($tail -eq 'collect,unbridge,stop,restore') ('cleanup order: ' + $tail)
    Assert-True ($calls[-1].checkpoint -eq $report.returnCheckpoint) 'wrong return checkpoint'
    if ($scenario -eq 'smoke') {
        Assert-True ($calls[0].action -eq 'protect') 'smoke changed state before protection'
        Assert-True ($report.returnCheckpoint -like 'akis-pre-*') 'smoke has no protection checkpoint'
        Assert-True ($calls[0].checkpoint -eq $report.returnCheckpoint -and $report.protectionRetained) 'protection checkpoint not retained'
    } else { Assert-True ($report.returnCheckpoint -eq 'baseline') 'dev did not restore baseline' }
    Assert-True (-not $report.ok) 'failed test was reported successful'
    Write-Output ('MOCK-OK ' + $scenario + ' rollback after test and collection failure')
}
# Load just the guest package/summary functions; intercept commands before any Pi can run.
$guestText = [IO.File]::ReadAllText((Join-Path $root 'guest-deploy.ps1'))
$tokens = $null; $errors = $null
$guestAst = [System.Management.Automation.Language.Parser]::ParseInput($guestText, [ref]$tokens, [ref]$errors)
foreach ($name in @('Invoke-StepPackages', 'Invoke-StepSummary', 'Invoke-StepDoctor', 'Get-RenderArgs')) {
    $definition = $guestAst.Find({param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name}, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Invoke-Captured {
    param($Label,$FilePath,$Arguments)
    if ($FilePath -eq 'node') { return [pscustomobject]@{exit=1;text='{"counts":{"PASS":0,"WARN":0,"FAIL":0},"results":[]}'} }
    Assert-True ($FilePath -eq 'pi' -and $Arguments[0] -eq 'install') 'unexpected native command in package step'
    $script:packageCalls += $Arguments[1]
    return [pscustomobject]@{exit=$script:packageExit;text='mock'}
}
function Write-StepJson { param($Name,$Object) $script:guestResult=$Object }
$script:RepoFull = (Resolve-Path (Join-Path $root '..\..')).ProviderPath
foreach ($Modules in @('core', 'core,memory')) {
    $script:packageCalls = @(); $script:packageExit=0
    Assert-True ((Invoke-StepPackages) -eq 0) 'package step failed'
    $expected=11; if($Modules -eq 'core,memory'){$expected=12}
    Assert-True ($script:packageCalls.Count -eq $expected) 'wrong number of plugin installations'
}
$script:packageExit=1
Assert-True ((Invoke-StepPackages) -ne 0) 'package install failure was ignored'
$OutDir=Join-Path $Scratch 'summary'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Assert-True ((Invoke-StepSummary) -ne 0) 'missing steps reported success'
foreach($name in @('prereq','render','knowledge','packages','stub','doctor')) {
    [IO.File]::WriteAllText((Join-Path $OutDir ($name+'.json')), '{"ok":true}')
}
Assert-True ((Invoke-StepSummary) -eq 0) 'complete summary failed'
[IO.File]::WriteAllText((Join-Path $OutDir 'knowledge.json'), '{"ok":false}')
Assert-True ((Invoke-StepSummary) -ne 0) 'failed knowledge reported success'
# The comma operator binds tighter than +, so an unparenthesised first element folded
# the whole render argument list into one space separated string; node then gets a
# single bogus module path. Assert one element per argument.
$Modules = 'core,memory'
$AgentDir = Join-Path $Scratch 'agent dir'
$renderArgs = @(Get-RenderArgs)
Assert-True ($renderArgs.Count -eq 24) ('render argument list has ' + $renderArgs.Count + ' element(s), expected 24')
Assert-True ($renderArgs[0] -eq ('scripts' + [IO.Path]::DirectorySeparatorChar + 'render.mjs')) ('render first argument is "' + $renderArgs[0] + '"')
Assert-True (@($renderArgs | Where-Object { $_ -match '\s--' }).Count -eq 0) 'a render argument still contains several flags'
Write-Output ('MOCK-OK render argument list keeps ' + $renderArgs.Count + ' separate elements')

function Write-GuestLog { param($Message) }
$AgentDir=Join-Path $Scratch 'unused-agent'
Assert-True ((Invoke-StepDoctor) -ne 0) 'doctor nonzero exit was ignored'
Write-Output 'MOCK-OK guest plugin installation, doctor exit and missing/failed step summaries'
Write-Output ('MOCKS-PASS PowerShell ' + $PSVersionTable.PSVersion)
