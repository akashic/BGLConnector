#Requires -Version 7.0
<#
  BglSpike.psm1 - shared helpers for the BGL SF360 spike.
  Signature format (from BGL's webhook docs):
    Authorization: "{clientCode} {UTC Date String} {Signature}"
    Signature = Base64( HMAC-SHA256( secret, "{UTC Date String}POST{URI String}{RequestBody}" ) )
#>

Add-Type -AssemblyName System.Web
$script:TimestampFormat = "yyyy-MM-dd'T'HH:mm:ss.fff'Z'"

function Get-BglEnvironment {
    param([ValidateSet('Staging', 'Production')][string]$Environment = 'Staging')
    # Production authorize URL is documented by BGL. The staging authorize URL is an
    # assumption based on the naming pattern - confirm it with api@bglcorp.com.au (T03).
    switch ($Environment) {
        'Staging' {
            [pscustomobject]@{
                Name         = 'Staging'
                ApiBase      = 'https://api.staging.bgl360.com.au'
                AuthorizeUrl = 'https://integrations.staging.bgl360.com.au/u/oauth/authorize'
                TokenUrl     = 'https://api.staging.bgl360.com.au/oauth/token'
            }
        }
        'Production' {
            [pscustomobject]@{
                Name         = 'Production'
                ApiBase      = 'https://api.bgl360.com.au'
                AuthorizeUrl = 'https://integrations.bgl360.com.au/u/oauth/authorize'
                TokenUrl     = 'https://api.bgl360.com.au/oauth/token'
            }
        }
    }
}

function Get-BglSignature {
    param(
        [Parameter(Mandatory)][string]$Timestamp,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [Parameter(Mandatory)][string]$Secret
    )
    $stringToSign = $Timestamp + 'POST' + $Url + $Body
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($Secret))
    try {
        [Convert]::ToBase64String($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stringToSign)))
    }
    finally { $hmac.Dispose() }
}

function New-BglAuthorizationHeader {
    param(
        [Parameter(Mandatory)][string]$ClientCode,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [Parameter(Mandatory)][string]$Secret,
        [datetime]$UtcNow = [datetime]::UtcNow
    )
    $ts = $UtcNow.ToUniversalTime().ToString($script:TimestampFormat, [Globalization.CultureInfo]::InvariantCulture)
    $sig = Get-BglSignature -Timestamp $ts -Url $Url -Body $Body -Secret $Secret
    "$($ClientCode.ToLowerInvariant()) $ts $sig"
}

function Test-BglAuthorizationHeader {
    param(
        [Parameter(Mandatory)][string]$AuthorizationHeader,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [Parameter(Mandatory)][string]$Secret,
        [string]$ExpectedClientCode,
        [int]$MaxSkewSeconds = 300,
        [datetime]$UtcNow = [datetime]::UtcNow
    )
    $result = [ordered]@{ IsValid = $false; Reason = ''; ClientCode = $null; Timestamp = $null; SkewSeconds = $null }
    # Split on single spaces only, exactly as BGL builds the header and as the connector's Verify does.
    $parts = $AuthorizationHeader.Trim() -split ' '
    if ($parts.Count -ne 3) { $result.Reason = "Expected 3 space-separated parts, got $($parts.Count)"; return [pscustomobject]$result }

    $result.ClientCode = $parts[0]; $result.Timestamp = $parts[1]
    if ($ExpectedClientCode -and $parts[0] -cne $ExpectedClientCode.ToLowerInvariant()) {
        $result.Reason = 'Client code mismatch'; return [pscustomobject]$result
    }

    $parsed = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [datetime]::TryParse($parts[1], [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        $result.Reason = 'Timestamp not parseable'; return [pscustomobject]$result
    }
    $result.SkewSeconds = [math]::Round(($UtcNow.ToUniversalTime() - $parsed).TotalSeconds, 1)

    $expected = Get-BglSignature -Timestamp $parts[1] -Url $Url -Body $Body -Secret $Secret
    $a = [System.Text.Encoding]::ASCII.GetBytes($expected)
    $b = [System.Text.Encoding]::ASCII.GetBytes($parts[2])
    if (-not [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($a, $b)) {
        $result.Reason = 'Signature mismatch'; return [pscustomobject]$result
    }
    if ($MaxSkewSeconds -gt 0 -and [math]::Abs($result.SkewSeconds) -gt $MaxSkewSeconds) {
        $result.Reason = "Signature valid but timestamp outside +/-$MaxSkewSeconds s window"; return [pscustomobject]$result
    }
    $result.IsValid = $true; $result.Reason = 'OK'
    [pscustomobject]$result
}

function Get-BglBasicAuthHeader {
    param([Parameter(Mandatory)][string]$ClientId, [Parameter(Mandatory)][string]$ClientSecret)
    'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$($ClientId):$($ClientSecret)"))
}

function Get-SpikeSecretsPath {
    $dir = Join-Path (Split-Path $PSScriptRoot -Parent) '.secrets'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $dir
}

function Save-BglToken {
    param([Parameter(Mandatory)]$Token, [Parameter(Mandatory)][string]$Environment)
    $path = Join-Path (Get-SpikeSecretsPath) "bgl-token-$($Environment.ToLowerInvariant()).json"
    $Token | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding utf8
    Write-Warning "Token saved in plain text to $path - spike use only. Delete it when finished."
    $path
}

function Read-BglToken {
    param([Parameter(Mandatory)][string]$Environment)
    $path = Join-Path (Get-SpikeSecretsPath) "bgl-token-$($Environment.ToLowerInvariant()).json"
    if (-not (Test-Path $path)) { throw "No saved token at $path. Run Get-BglToken.ps1 first." }
    Get-Content $path -Raw | ConvertFrom-Json
}

function Write-SpikeResult {
    param([Parameter(Mandatory)]$Data, [Parameter(Mandatory)][string]$Name)
    $dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'results'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $path = Join-Path $dir ("{0}-{1}.json" -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding utf8
    Write-Host "Results written to $path" -ForegroundColor Cyan
    $path
}

Export-ModuleMember -Function *
