#Requires -Version 7.0
<#
.SYNOPSIS
  T01 - Offline check that the harness signing/verification matches BGL's published worked example.
  No network, no credentials. Exit code 0 = all pass.
#>
Import-Module (Join-Path $PSScriptRoot 'BglSpike.psm1') -Force

$ts       = '2020-09-09T06:18:33.082Z'
$url      = 'https://provider-site.com/api/bgl/messages'
$secret   = 'my-secrete-key'
$body     = '{"entityId":"8ad08a066555bb32016555d9ebac0003","eventId":"039403940","eventType":"audit","firmId":"bgltest","tenants":[{"tenantId":"ASFAUDIT4550","tenantType":"fundCode"},{"tenantId":"73124784265","tenantType":"abn"},{"tenantId":"2015/2016","tenantType":"financialYear"}],"userId":"info@bglcorp.com.au"}'
$expected = 'fcCSdGwSgTXseS5eFWOphImuEM9LT6KjgHfuiPWB48A='
$header   = "provider1 $ts $expected"
$exampleTime = [datetime]::Parse($ts, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)

$tests = @(
    @{ Name = 'Signature matches BGL example'; Pass = ((Get-BglSignature -Timestamp $ts -Url $url -Body $body -Secret $secret) -ceq $expected) }
    @{ Name = 'Header verifies (correct inputs)'; Pass = (Test-BglAuthorizationHeader -AuthorizationHeader $header -Url $url -Body $body -Secret $secret -ExpectedClientCode 'provider1' -UtcNow $exampleTime).IsValid }
    @{ Name = 'Rejects modified body'; Pass = -not (Test-BglAuthorizationHeader -AuthorizationHeader $header -Url $url -Body ($body -replace 'audit', 'Audit') -Secret $secret -UtcNow $exampleTime).IsValid }
    @{ Name = 'Rejects re-serialised body (pretty JSON)'; Pass = -not (Test-BglAuthorizationHeader -AuthorizationHeader $header -Url $url -Body ($body | ConvertFrom-Json | ConvertTo-Json -Depth 5) -Secret $secret -UtcNow $exampleTime).IsValid }
    @{ Name = 'Rejects different URL (query string added)'; Pass = -not (Test-BglAuthorizationHeader -AuthorizationHeader $header -Url "${url}?sig=abc" -Body $body -Secret $secret -UtcNow $exampleTime).IsValid }
    @{ Name = 'Rejects tab-separated header (same rule as the connector)'; Pass = -not (Test-BglAuthorizationHeader -AuthorizationHeader ($header -replace ' ', "`t") -Url $url -Body $body -Secret $secret -UtcNow $exampleTime).IsValid }
    @{ Name = 'Rejects wrong secret'; Pass = -not (Test-BglAuthorizationHeader -AuthorizationHeader $header -Url $url -Body $body -Secret 'wrong' -UtcNow $exampleTime).IsValid }
    @{ Name = 'Rejects stale timestamp (skew window)'; Pass = -not (Test-BglAuthorizationHeader -AuthorizationHeader $header -Url $url -Body $body -Secret $secret -MaxSkewSeconds 300).IsValid }
    @{ Name = 'Round trip: new header verifies now'; Pass = (Test-BglAuthorizationHeader -AuthorizationHeader (New-BglAuthorizationHeader -ClientCode 'SPIKE' -Url $url -Body $body -Secret $secret) -Url $url -Body $body -Secret $secret -ExpectedClientCode 'spike').IsValid }
)

$failed = 0
foreach ($t in $tests) {
    if ($t.Pass) { Write-Host "PASS  $($t.Name)" -ForegroundColor Green }
    else { Write-Host "FAIL  $($t.Name)" -ForegroundColor Red; $failed++ }
}
Write-Host ''
if ($failed) { Write-Host "$failed test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All signature tests passed' -ForegroundColor Green
exit 0
