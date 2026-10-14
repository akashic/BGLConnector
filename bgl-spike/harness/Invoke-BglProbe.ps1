#Requires -Version 7.0
<#
.SYNOPSIS
  T06, T13, T14, T15 - Probes BGL API endpoints with the saved token. Read-only by default.

.DESCRIPTION
  For each endpoint records: HTTP status (200 vs 401/403 shows scope coverage), latency,
  rate-limit headers, response shape, and any date-like fields (to judge polling feasibility).
  Probing uses ~15 calls; BGL's default limit is 100 per 10 minutes and 1000 per day.

  -WriteTestContactId performs an IDEMPOTENT write on Staging: reads one contact and PUTs the same
  values back, limited to the fields BGL documents for PUT /sf/contacts/{id}. Read-only and masked
  GET fields (contactId, contactType, entityRelationships, addressId, and tfn, which GET returns as
  'Provided'/'Not Provided') are never sent. 401/403 = scope problem; 400 = request shape problem.
  The write is skipped unless the read returned HTTP 200 with the requested contact, and it asks
  for confirmation (pass -Confirm:$false to skip the prompt).

  BGL does not document whether PUT leaves omitted fields alone or clears them, so use a throwaway
  staging contact. The whole record is compared before and after, and any changed field (including
  tfn going from 'Provided' to 'Not Provided') is reported.

.EXAMPLE
  ./Invoke-BglProbe.ps1
.EXAMPLE
  ./Invoke-BglProbe.ps1 -FundId 8ad08a06... -WriteTestContactId 8ad0...
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Staging', 'Production')][string]$Environment = 'Staging',
    [string]$FundId,
    [string]$WriteTestContactId,
    [switch]$AllowProductionWrite,
    [int]$ModifiedAfterDays = 30,
    [int]$FinancialYear,
    [string]$ApiBase
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'BglSpike.psm1') -Force

$envCfg = Get-BglEnvironment -Environment $Environment
if ($ApiBase) { $envCfg.ApiBase = $ApiBase.TrimEnd('/') }
$token = Read-BglToken -Environment $Environment
# A stale token makes every probe return 401, which would read as "scope does not reach this endpoint".
$expiresAt = if ($token.access_token_expires_at) { [DateTimeOffset]::FromUnixTimeSeconds([long]$token.access_token_expires_at).UtcDateTime }
             elseif ($token.obtained_at_utc -and $token.expires_in) { ([datetime]$token.obtained_at_utc).ToUniversalTime().AddSeconds([double]$token.expires_in) }
if (-not $expiresAt) { Write-Warning 'Saved token has no expiry information - treat 401 results with suspicion.' }
elseif ($expiresAt -le [datetime]::UtcNow) { throw "Saved access token expired at $($expiresAt.ToString('u')). Run Get-BglToken.ps1 again before probing." }
$headers = @{ Authorization = "Bearer $($token.access_token)"; Accept = 'application/json' }
$results = [System.Collections.Generic.List[object]]::new()

function Get-DateLikeFields {
    param($Obj, [string]$Prefix = '', [int]$Depth = 0)
    if ($null -eq $Obj -or $Depth -gt 3) { return }
    if ($Obj -is [System.Collections.IEnumerable] -and $Obj -isnot [string]) {
        $first = @($Obj) | Select-Object -First 1
        Get-DateLikeFields -Obj $first -Prefix "$Prefix[0]" -Depth ($Depth + 1); return
    }
    if ($Obj -is [pscustomobject]) {
        foreach ($p in $Obj.PSObject.Properties) {
            $path = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }
            if ($p.Name -match '(?i)date|modified|updated|created|timestamp|lastChange') { "$path=$($p.Value)" }
            elseif ($p.Value -is [pscustomobject] -or ($p.Value -is [System.Collections.IEnumerable] -and $p.Value -isnot [string])) {
                Get-DateLikeFields -Obj $p.Value -Prefix $path -Depth ($Depth + 1)
            }
        }
    }
}

function Invoke-Probe {
    param([string]$Id, [string]$Question, [string]$Path, [string]$Method = 'GET', $Body)
    $uri = "$($envCfg.ApiBase)$Path"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $params = @{ Method = $Method; Uri = $uri; Headers = $headers; SkipHttpErrorCheck = $true }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress); $params.ContentType = 'application/json' }
    $r = Invoke-WebRequest @params
    $sw.Stop()
    $status = [int]$r.StatusCode
    $json = $null; try { $json = $r.Content | ConvertFrom-Json -Depth 20 -NoEnumerate } catch { }
    $shape = if ($null -eq $json) { 'non-JSON' }
             elseif ($json -is [array]) { "array[$($json.Count)]" }
             else { 'object{' + (($json.PSObject.Properties.Name | Select-Object -First 8) -join ',') + '}' }
    $rate = ($r.Headers.Keys | Where-Object { $_ -match '(?i)rate' } | ForEach-Object { "$_=$($r.Headers[$_] -join ',')" }) -join '; '
    $row = [pscustomobject]@{
        Id = $Id; Question = $Question; Method = $Method; Path = $Path; Status = $status; Ms = $sw.ElapsedMilliseconds
        Shape = $shape; RateHeaders = $rate
        DateFields = ((Get-DateLikeFields -Obj $json | Select-Object -First 6) -join ' | ')
        Error = if ($status -ge 400) { $text = "$($r.Content)".Trim(); $text.Substring(0, [math]::Min(250, $text.Length)) }
    }
    $results.Add($row)
    $colour = if ($row.Status -lt 300) { 'Green' } elseif ($row.Status -in 401, 403) { 'Yellow' } else { 'Red' }
    Write-Host ("{0,-4} {1,-6} {2,3} {3,5}ms  {4}" -f $Id, $Method, $row.Status, $row.Ms, $Path) -ForegroundColor $colour
    # Wrapped so callers get the status with the body, and a one-element array is not unrolled.
    [pscustomobject]@{ Status = $status; Json = $json }
}

# Builds a PUT /sf/contacts/{id} body from a GET /sf/contactsByIds record, keeping only the fields
# BGL documents for the update. tfn is excluded on purpose: GET returns it masked, so echoing it back
# would overwrite the real TFN with 'Provided'.
function ConvertTo-BglContactUpdate {
    param([Parameter(Mandatory)]$Contact)
    $fields = 'title', 'firstName', 'lastName', 'otherName', 'preferredName', 'name', 'sex', 'birthday',
              'birthPlace', 'birthState', 'birthCountry', 'dateOfDeath', 'din', 'abn', 'acn', 'email',
              'telephone', 'mobile', 'smsfAuditorNumber', 'professionalBody', 'professionalBodyNumber',
              'usi', 'memberAccountNumber', 'spin', 'establishmentDate'
    $out = [ordered]@{}
    foreach ($f in $fields) { if ($null -ne $Contact.$f) { $out[$f] = $Contact.$f } }
    # GET can return sex as 'MALE'; PUT accepts only 'Male'/'Female'. abn/acn are sent exactly as read:
    # converting them to numbers (as the PUT table suggests) would drop an ACN's leading zero.
    if ($out.Contains('sex')) { $out['sex'] = (Get-Culture).TextInfo.ToTitleCase("$($out['sex'])".ToLowerInvariant()) }
    if ($Contact.address) {
        $addr = [ordered]@{}
        foreach ($f in 'streetLine1', 'streetLine2', 'city', 'state', 'postCode', 'country') {
            if ($null -ne $Contact.address.$f) { $addr[$f] = $Contact.address.$f }
        }
        if ($addr.Count) { $out['address'] = $addr }
    }
    [pscustomobject]$out
}

# Names of top-level fields whose values differ between two records (compared as compact JSON).
function Compare-BglRecord {
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After)
    $names = @($Before.PSObject.Properties.Name) + @($After.PSObject.Properties.Name) | Sort-Object -Unique
    foreach ($n in $names) {
        if (($Before.$n | ConvertTo-Json -Depth 10 -Compress) -cne ($After.$n | ConvertTo-Json -Depth 10 -Compress)) { $n }
    }
}

$since = (Get-Date).ToUniversalTime().AddDays(-$ModifiedAfterDays).ToString('yyyy-MM-dd')
# Australian financial years run 1 July - 30 June and SF360 labels them by the year they end in
# (a fund's financialYearEnd is e.g. 2021-06-30). BGL documents the parameter only as "YYYY".
if (-not $FinancialYear) { $today = Get-Date; $FinancialYear = if ($today.Month -ge 7) { $today.Year + 1 } else { $today.Year } }

Write-Host "`n--- Identity and limits ---" -ForegroundColor Cyan
Invoke-Probe P01 'Who authorised the token' '/user/detail' | Out-Null
Invoke-Probe P02 'Which firm (bglAccountId)' '/account/detail' | Out-Null
Invoke-Probe P03 'Rate limit status (free call)' '/client/rateLimitStatus' | Out-Null

Write-Host "`n--- SF360 entity access (scope coverage) ---" -ForegroundColor Cyan
$funds = Invoke-Probe P04 'List entities/funds' '/fund/list'
if (-not $FundId -and $funds.Status -eq 200) {
    # BGL documents the response as { "funds": [ { "fundID": ... } ] }; also accept a bare array.
    $list = if ($null -ne $funds.Json.funds) { $funds.Json.funds } else { $funds.Json }
    $first = @($list) | Select-Object -First 1
    $FundId = @($first.fundID, $first.id, $first.entityId) | Where-Object { $_ } | Select-Object -First 1
    if ($FundId) { Write-Host "Using first fund: $FundId" -ForegroundColor DarkGray }
}
if ($FundId) {
    Invoke-Probe P05 'Entity details' "/sf/funds/$FundId" | Out-Null
    Invoke-Probe P06 'Fund trustees' "/sf/funds/$FundId/trustees" | Out-Null
    Invoke-Probe P07 'Entity contacts' "/sf/funds/$FundId/contacts" | Out-Null
    Invoke-Probe P08 'Entity documents (dates for polling?)' "/funds/$FundId/documents" | Out-Null
    Invoke-Probe P09 'Workpapers (audit scope)' "/sf/funds/$FundId/workpapers/?financialYear=$FinancialYear" | Out-Null
}
else { Write-Warning 'No fund id found - pass -FundId to probe entity endpoints.' }

Write-Host "`n--- Firm-wide lists (polling candidates) ---" -ForegroundColor Cyan
Invoke-Probe P10 'Firm contacts (paging)' '/sf/contacts?offset=0&limit=5' | Out-Null
Invoke-Probe P11 "Firm lodgements modified after $since" "/sf/firm/lodgements?modifiedAfter=$since" | Out-Null
Invoke-Probe P12 'Workflow jobs (status changes?)' '/sf/workflow/jobs?page=0&size=5' | Out-Null
Invoke-Probe P13 'CAS companies (cas scope?)' '/cas/companies?offset=0&limit=5' | Out-Null
Invoke-Probe P14 "CAS documents updated after $since" "/cas/documents?offset=0&limit=5&updatedAfter=$since" | Out-Null

if ($WriteTestContactId) {
    Write-Host "`n--- Idempotent write test ---" -ForegroundColor Cyan
    if ($Environment -eq 'Production' -and -not $AllowProductionWrite) {
        Write-Warning 'Write test skipped on Production. Use -AllowProductionWrite only if you really mean it.'
    }
    else {
        $existing = Invoke-Probe W01 'Read contact before write' "/sf/contactsByIds?ids=$WriteTestContactId"
        $record = if ($existing.Status -eq 200) {
            @($existing.Json) | Where-Object { $_.contactId -eq $WriteTestContactId } | Select-Object -First 1
        }
        if (-not $record) {
            Write-Warning "Write test skipped: the read returned HTTP $($existing.Status) without contact $WriteTestContactId."
        }
        elseif ($PSCmdlet.ShouldProcess("contact $WriteTestContactId ($Environment)", 'PUT its documented fields back unchanged; omitted fields may be cleared')) {
            $body = ConvertTo-BglContactUpdate -Contact $record
            $put = Invoke-Probe W02 'PUT same values back (permission check)' "/sf/contacts/$WriteTestContactId" -Method PUT -Body $body
            $after = Invoke-Probe W03 'Read contact after write' "/sf/contactsByIds?ids=$WriteTestContactId"
            $afterRecord = if ($after.Status -eq 200) { @($after.Json) | Where-Object { $_.contactId -eq $WriteTestContactId } | Select-Object -First 1 }
            if (-not $afterRecord) { Write-Warning "Could not re-read the contact (HTTP $($after.Status)) - check it by hand." }
            else {
                # Compare the WHOLE record, not just the fields sent, so collateral damage shows up.
                $changed = @(Compare-BglRecord -Before $record -After $afterRecord)
                if ($changed.Count) { Write-Host "PUT HTTP $($put.Status) changed fields: $($changed -join ', ')" -ForegroundColor Red }
                else { Write-Host "PUT HTTP $($put.Status); record unchanged." -ForegroundColor Green }
                $results[-1] | Add-Member -NotePropertyName ChangedFields -NotePropertyValue $changed
            }
        }
    }
}

Write-Host ''
foreach ($r in $results) { Write-Host ("{0,-4} {1,3}  {2}  {3}" -f $r.Id, $r.Status, $r.Shape, $r.DateFields) }
Write-SpikeResult -Data ([ordered]@{ environment = $Environment; fundId = $FundId; grantedScope = $token.scope; probes = $results }) -Name 'api-probe' | Out-Null
