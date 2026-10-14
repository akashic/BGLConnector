#Requires -Version 7.0
<#
.SYNOPSIS
  T08, T10, T11 - Simulates BGL sending a signed webhook, so receivers can be tested without BGL.

.DESCRIPTION
  Builds a message in BGL's documented format, signs it exactly as BGL describes, and POSTs the
  exact signed bytes to -Url. Use -Tamper to confirm the receiver rejects bad messages.

  Use a throwaway secret for simulator tests - never the real BGL secret.

.EXAMPLE
  # Valid message to a Power Automate HTTP trigger
  ./Send-BglTestWebhook.ps1 -Url $flowUrl -Secret 'spike-test-secret' -ClientCode spike
.EXAMPLE
  # Run the full tamper suite
  ./Send-BglTestWebhook.ps1 -Url $flowUrl -Secret 'spike-test-secret' -ClientCode spike -Tamper All
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Secret,
    [string]$ClientCode = 'spike',
    [ValidateSet('audit', 'newCompany', 'identityCheck', 'documentChange', 'newDocument', 'deleteDocument', 'newStatus', 'newAttachment')]
    [string]$EventType = 'audit',
    [string]$EntityId = '8ad08a066555bb32016555d9ebac0003',
    [string]$FirmId = 'spiketest',
    [string]$FundCode = 'SPIKEFUND01',
    [string]$Abn = '73124784265',
    [string]$FinancialYear = '2025/2026',
    [string]$UserId = 'spike@example.com',
    [string]$BodyFile,
    [ValidateSet('None', 'Body', 'Signature', 'Timestamp', 'Url', 'ClientCode', 'All')][string]$Tamper = 'None'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'BglSpike.psm1') -Force

function New-Body {
    if ($BodyFile) { return (Get-Content $BodyFile -Raw).Trim() }
    # Compact JSON, field order as in BGL's example payload.
    $msg = [ordered]@{
        entityId  = $EntityId
        eventId   = [string](Get-Random -Minimum 100000000 -Maximum 999999999)
        eventType = $EventType
        firmId    = $FirmId
        tenants   = @(
            [ordered]@{ tenantId = $FundCode; tenantType = 'fundCode' },
            [ordered]@{ tenantId = $Abn; tenantType = 'abn' },
            [ordered]@{ tenantId = $FinancialYear; tenantType = 'financialYear' }
        )
        userId    = $UserId
    }
    if ($EventType -eq 'documentChange') { $msg.Insert(3, 'eventSubType', 'createdOrUpdated') }
    $msg | ConvertTo-Json -Depth 5 -Compress
}

function Send-One {
    param([string]$Case)
    $body = New-Body
    $signedUrl = $Url; $sentBody = $body; $utc = [datetime]::UtcNow; $code = $ClientCode
    switch ($Case) {
        'Url'       { $signedUrl = "$Url&tampered=1" }          # signed for a different URL
        'Timestamp' { $utc = $utc.AddHours(-2) }                 # valid signature, stale timestamp
        'ClientCode' { $code = 'someoneelse' }
    }
    $auth = New-BglAuthorizationHeader -ClientCode $code -Url $signedUrl -Body $body -Secret $Secret -UtcNow $utc
    switch ($Case) {
        'Body' {
            # Works on compact or pretty-printed bodies; falls back to adding a field if there is no eventType.
            $sentBody = $body -replace '("eventType"\s*:\s*)"[^"]*"', '$1"tampered"'
            if ($sentBody -ceq $body) { $sentBody = $body.TrimEnd().TrimEnd('}') + ',"tampered":true}' }
        }
        'Signature' { $p = $auth -split ' '; $auth = "$($p[0]) $($p[1]) $([Convert]::ToBase64String([byte[]](1..32)))" }
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($sentBody)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-WebRequest -Method Post -Uri $Url -Body $bytes -ContentType 'application/json' `
        -Headers @{ Authorization = $auth } -SkipHttpErrorCheck
    $sw.Stop()
    $expectReject = $Case -ne 'None'
    $accepted = [int]$r.StatusCode -lt 300
    [pscustomobject]@{
        Case = $Case; Status = [int]$r.StatusCode; Ms = $sw.ElapsedMilliseconds
        Expected = if ($expectReject) { 'reject' } else { 'accept' }
        Outcome = if ($accepted -ne $expectReject) { 'AS EXPECTED' } else { 'UNEXPECTED' }
        Response = ($r.Content | Out-String).Trim() -replace '\s+', ' ' | ForEach-Object { $_.Substring(0, [math]::Min(160, $_.Length)) }
        AuthorizationSent = $auth
    }
}

$cases = if ($Tamper -eq 'All') { 'None', 'Body', 'Signature', 'Timestamp', 'Url', 'ClientCode' } else { @($Tamper) }
$out = foreach ($c in $cases) { Send-One -Case $c }
foreach ($o in $out) {
    $colour = if ($o.Outcome -eq 'AS EXPECTED') { 'Green' } else { 'Red' }
    Write-Host ("{0,-10} HTTP {1,3}  {2,5}ms  expected {3,-6}  {4}  {5}" -f $o.Case, $o.Status, $o.Ms, $o.Expected, $o.Outcome, $o.Response) -ForegroundColor $colour
}
Write-Host 'Note: a receiver that only logs (no verification) will accept everything - that is expected for T11 inspection runs.' -ForegroundColor DarkGray
Write-SpikeResult -Data ([ordered]@{ url = ($Url -replace 'sig=[^&]+', 'sig=REDACTED'); eventType = $EventType; results = $out }) -Name 'webhook-sim' | Out-Null
