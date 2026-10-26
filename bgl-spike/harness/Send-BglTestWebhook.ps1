#Requires -Version 7.0
<#
.SYNOPSIS
  T08, T10, T11, T17 - Simulates BGL sending a signed webhook, so receivers can be tested without BGL.

.DESCRIPTION
  Builds a message in BGL's documented format, signs it exactly as BGL describes, and POSTs the
  exact signed bytes to -Url. Use -Tamper to confirm the receiver rejects bad messages.

  Use a throwaway secret for simulator tests - never the real BGL secret.

  A Power Automate HTTP trigger rejects any request that carries both the sig= SAS in its URL and an
  Authorization header (401 DirectApiRequestHasMoreThanOneAuthorization), before the flow runs. So
  BGL's header can't reach a flow directly: use -HeaderName to send it under another name, as a fixed
  receiver in front of the flow would.

.EXAMPLE
  # Valid message to a Power Automate HTTP trigger
  ./Send-BglTestWebhook.ps1 -Url $flowUrl -Secret 'spike-test-secret' -ClientCode spike -HeaderName X-BGL-Authorization
.EXAMPLE
  # Run the full tamper suite
  ./Send-BglTestWebhook.ps1 -Url $flowUrl -Secret 'spike-test-secret' -ClientCode spike -HeaderName X-BGL-Authorization -Tamper All
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
    # Compact: single-line JSON. Bgl: BGL's documented webhook template, with a newline after each
    # top-level field. Run T11 with both: Flow A re-serialises the body, which compact JSON survives
    # but BGL's layout may not.
    [ValidateSet('Compact', 'Bgl')][string]$BodyStyle = 'Compact',
    # Replay sends the same signed message twice: a receiver that de-duplicates on eventId (the Azure receiver, T17)
    # accepts both but forwards once, and reports "duplicate":true on the second when it exposes reasons.
    [ValidateSet('None', 'Body', 'Signature', 'Timestamp', 'Url', 'ClientCode', 'Replay', 'All')][string]$Tamper = 'None',
    # Header that carries BGL's signature. BGL itself always uses Authorization; see the description.
    [ValidatePattern('^[A-Za-z0-9-]+$')][string]$HeaderName = 'Authorization'
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
    if ($BodyStyle -eq 'Bgl') {
        $fields = foreach ($k in $msg.Keys) { (ConvertTo-Json $k) + ':' + (ConvertTo-Json $msg[$k] -Depth 5 -Compress) }
        return '{' + ($fields -join ",`n") + '}'
    }
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
    $send = { Invoke-WebRequest -Method Post -Uri $Url -Body $bytes -ContentType 'application/json' `
        -Headers @{ $HeaderName = $auth } -SkipHttpErrorCheck }
    if ($Case -eq 'Replay') { & $send | Out-Null }   # the first copy; the second is the one reported
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = & $send
    $sw.Stop()
    $expectReject = $Case -notin 'None', 'Replay'
    $accepted = [int]$r.StatusCode -lt 300
    [pscustomobject]@{
        Case = $Case; Status = [int]$r.StatusCode; Ms = $sw.ElapsedMilliseconds
        Expected = if ($expectReject) { 'reject' } else { 'accept' }
        # 202 means the receiver queued the message without a verdict (e.g. a flow with no Response action).
        Outcome = if ([int]$r.StatusCode -eq 202) { 'NO VERDICT' } elseif ($accepted -ne $expectReject) { 'AS EXPECTED' } else { 'UNEXPECTED' }
        Response = ($r.Content | Out-String).Trim() -replace '\s+', ' ' | ForEach-Object { $_.Substring(0, [math]::Min(160, $_.Length)) }
        AuthorizationSent = $auth
    }
}

$cases = if ($Tamper -eq 'All') { 'None', 'Body', 'Signature', 'Timestamp', 'Url', 'ClientCode', 'Replay' } else { @($Tamper) }
$out = foreach ($c in $cases) { Send-One -Case $c }
foreach ($o in $out) {
    $colour = switch ($o.Outcome) { 'AS EXPECTED' { 'Green' } 'NO VERDICT' { 'Yellow' } default { 'Red' } }
    Write-Host ("{0,-10} HTTP {1,3}  {2,5}ms  expected {3,-6}  {4}  {5}" -f $o.Case, $o.Status, $o.Ms, $o.Expected, $o.Outcome, $o.Response) -ForegroundColor $colour
}
Write-Host 'Note: a receiver that only logs (no verification) will accept everything - that is expected for T11 inspection runs.' -ForegroundColor DarkGray
Write-SpikeResult -Data ([ordered]@{ url = ($Url -replace 'sig=[^&]+', 'sig=REDACTED'); eventType = $EventType; bodyStyle = $BodyStyle; headerName = $HeaderName; results = $out }) -Name 'webhook-sim' | Out-Null
