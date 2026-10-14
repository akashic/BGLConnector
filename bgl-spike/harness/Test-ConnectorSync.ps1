#Requires -Version 7.0
<#
.SYNOPSIS
  Offline check that the two connector scripts and the connector definition agree.
  No network, no credentials. Exit code 0 = all pass.

.DESCRIPTION
  A custom connector can have only one script, so script.csx and script-with-proxy.csx duplicate
  their shared code. This checks that:
    - the code between the BEGIN SHARED / END SHARED markers is identical in both scripts;
    - the operations routed to code agree everywhere: scriptOperations in apiProperties.json,
      operationIds in apiDefinition.swagger.json, and KnownOperations in both scripts.
#>
$connector = Join-Path (Split-Path $PSScriptRoot -Parent) 'connector'
$core = Get-Content (Join-Path $connector 'script.csx') -Raw
$proxy = Get-Content (Join-Path $connector 'script-with-proxy.csx') -Raw

function Get-SharedBlock {
    param([string]$Text)
    $m = [regex]::Match($Text, '(?s)// ===== BEGIN SHARED.*?\n(.*?)\s*// ===== END SHARED =====')
    if ($m.Success) { $m.Groups[1].Value -replace "`r`n", "`n" } else { $null }
}

function Get-KnownOperations {
    param([string]$Text)
    $m = [regex]::Match($Text, '(?s)KnownOperations\s*=\s*\{(.*?)\}')
    if ($m.Success) { [regex]::Matches($m.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object }
}

$scriptOps = (Get-Content (Join-Path $connector 'apiProperties.json') -Raw | ConvertFrom-Json).properties.scriptOperations | Sort-Object
$swagger = Get-Content (Join-Path $connector 'apiDefinition.swagger.json') -Raw | ConvertFrom-Json
$swaggerOps = foreach ($path in $swagger.paths.PSObject.Properties) {
    foreach ($op in $path.Value.PSObject.Properties) { $op.Value.operationId }
}
$coreShared = Get-SharedBlock $core
$proxyShared = Get-SharedBlock $proxy

$tests = @(
    @{ Name = 'Shared block present in both scripts'; Pass = ($null -ne $coreShared -and $null -ne $proxyShared) }
    @{ Name = 'Shared block identical in both scripts'; Pass = ($coreShared -ceq $proxyShared) }
    @{ Name = 'KnownOperations identical in both scripts'; Pass = ((Get-KnownOperations $core) -join ',') -ceq ((Get-KnownOperations $proxy) -join ',') }
    @{ Name = 'KnownOperations match apiProperties scriptOperations'; Pass = ((Get-KnownOperations $core) -join ',') -ceq ($scriptOps -join ',') }
    @{ Name = 'Every scriptOperation exists in the swagger'; Pass = -not ($scriptOps | Where-Object { $_ -cnotin $swaggerOps }) }
)

$failed = 0
foreach ($t in $tests) {
    if ($t.Pass) { Write-Host "PASS  $($t.Name)" -ForegroundColor Green }
    else { Write-Host "FAIL  $($t.Name)" -ForegroundColor Red; $failed++ }
}
Write-Host ''
if ($failed) { Write-Host "$failed check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'Connector scripts and definition are in sync' -ForegroundColor Green
exit 0
