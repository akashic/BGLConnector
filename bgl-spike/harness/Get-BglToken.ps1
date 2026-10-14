#Requires -Version 7.0
<#
.SYNOPSIS
  T02, T03, T05 - Runs BGL's Authorization Code flow and tests which token request styles BGL accepts.

.DESCRIPTION
  BGL documents the token call as a POST with parameters in the QUERY STRING and the client
  credentials in a Basic Authorization header. Power Platform's generic OAuth 2.0 provider is
  expected to send a standard form-encoded BODY instead. This script tries each style to find out,
  before building the connector, whether the generic provider is likely to work.

  Authorization codes are single-use and expire after 10 minutes, so each style gets its own
  browser authorization. After your first consent, BGL should redirect straight back.

  Register the redirect URI (default http://127.0.0.1:8765/callback) on your BGL app in the
  Developer Portal first. BGL blocks "localhost" but allows 127.0.0.1.

.EXAMPLE
  ./Get-BglToken.ps1 -ClientId '<id>' -Scope smsf_partner -TestAllStyles
.EXAMPLE
  ./Get-BglToken.ps1 -ClientId '<id>' -Scope 'smsf_partner+cas_incorporator' -TokenStyle BglDocumented
#>
[CmdletBinding()]
param(
    [ValidateSet('Staging', 'Production')][string]$Environment = 'Staging',
    [Parameter(Mandatory)][string]$ClientId,
    [securestring]$ClientSecret,
    [string]$Scope = 'smsf_partner',
    [string]$RedirectUri = 'http://127.0.0.1:8765/callback',
    [string]$AuthorizeUrl,
    [string]$TokenUrl,
    [ValidateSet('BglDocumented', 'FormBody', 'FormBodyWithScope', 'FormBodyBasicAuth')][string]$TokenStyle = 'BglDocumented',
    [switch]$TestAllStyles,
    [switch]$SkipRefreshTest,
    [switch]$ManualCode
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'BglSpike.psm1') -Force

$envCfg = Get-BglEnvironment -Environment $Environment
if ($AuthorizeUrl) { $envCfg.AuthorizeUrl = $AuthorizeUrl }
if ($TokenUrl) { $envCfg.TokenUrl = $TokenUrl }
if (-not $ClientSecret) { $ClientSecret = Read-Host -AsSecureString -Prompt 'BGL client secret' }
$secretPlain = [System.Net.NetworkCredential]::new('', $ClientSecret).Password
$basic = Get-BglBasicAuthHeader -ClientId $ClientId -ClientSecret $secretPlain
$scopeList = $Scope -split '[+ ]' | Where-Object { $_ }
$scopeQuery = ($scopeList | ForEach-Object { [uri]::EscapeDataString($_) }) -join '+'
# Form bodies get the scopes space-separated (RFC 6749); form encoding then puts them on the wire as
# 'a+b', the same bytes as $scopeQuery. Passing $Scope itself would send a literal plus as %2B.
$scopeForm = $scopeList -join ' '

function Wait-ForAuthCode {
    param([string]$ExpectedState)
    $redirect = [uri]$RedirectUri
    if ($ManualCode) {
        $pasted = Read-Host 'Paste the full URL your browser was redirected to'
        $q = [System.Web.HttpUtility]::ParseQueryString(([uri]$pasted).Query)
    }
    else {
        # Minimal one-shot HTTP listener on a raw socket (no admin rights or URL ACLs needed).
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse($redirect.Host), $redirect.Port)
        $listener.Start()
        Write-Host "Waiting for BGL redirect on $RedirectUri (Ctrl+C to abort)..." -ForegroundColor Yellow
        $target = $null
        try {
            # Browsers may open speculative connections or request /favicon.ico, so keep
            # accepting until a request carrying code= or error= arrives.
            for ($i = 0; $i -lt 20 -and -not $target; $i++) {
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $stream.ReadTimeout = 5000
                    $reader = [System.IO.StreamReader]::new($stream)
                    $requestLine = try { $reader.ReadLine() } catch { $null }
                    $path = if ($requestLine) { ($requestLine -split ' ')[1] } else { $null }
                    if ($path -and $path -match '[?&](code|error)=') {
                        $target = $path
                        $html = '<html><body style="font-family:sans-serif"><h3>BGL spike: code received.</h3>You can close this tab.</body></html>'
                        $status = '200 OK'
                    }
                    else { $html = ''; $status = '404 Not Found' }
                    if ($requestLine) {
                        $resp = "HTTP/1.1 $status`r`nContent-Type: text/html`r`nContent-Length: $([System.Text.Encoding]::UTF8.GetByteCount($html))`r`nConnection: close`r`n`r`n$html"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($resp)
                        $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
                    }
                }
                finally { $client.Close() }
            }
        }
        finally { $listener.Stop() }
        if (-not $target) { throw 'No authorization redirect received. Re-run with -ManualCode to paste the redirect URL instead.' }
        $q = [System.Web.HttpUtility]::ParseQueryString(([uri]"http://127.0.0.1$target").Query)
    }
    if ($q['error']) { throw "BGL returned error: $($q['error']) $($q['error_description'])" }
    if ($ExpectedState -and $q['state'] -ne $ExpectedState) { throw 'State mismatch - possible CSRF or stale redirect' }
    if (-not $q['code']) { throw 'No authorization code in redirect' }
    $q['code']
}

function Get-AuthCode {
    $state = [guid]::NewGuid().ToString('N')
    $url = "$($envCfg.AuthorizeUrl)?response_type=code&client_id=$([uri]::EscapeDataString($ClientId))&scope=$scopeQuery&redirect_uri=$([uri]::EscapeDataString($RedirectUri))&state=$state"
    Write-Host "`nOpening browser for BGL authorization:`n$url`n"
    try { Start-Process $url } catch { Write-Host 'Could not open a browser - open the URL above manually.' }
    Wait-ForAuthCode -ExpectedState $state
}

function Invoke-TokenRequest {
    param([string]$Style, [hashtable]$Grant)   # Grant: grant_type + code/redirect_uri or refresh_token
    $headers = @{ Accept = 'application/json' }
    $uri = $envCfg.TokenUrl; $body = $null; $contentType = $null
    switch ($Style) {
        'BglDocumented' {
            # Exactly as BGL documents: params in query string, Basic auth, empty body.
            # Scope reuses $scopeQuery so multiple scopes go out joined by a literal '+', the same as on
            # the authorize call (BGL: "separated by a '+' symbol" in both URLs).
            $q = ($Grant.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString($_.Value))" }) + "scope=$scopeQuery"
            $uri += '?' + ($q -join '&')
            $headers.Authorization = $basic
        }
        'FormBody' {
            # Approximates Power Platform's generic OAuth 2.0 provider: form body, client creds in body, no scope.
            $p = $Grant.Clone(); $p['client_id'] = $ClientId; $p['client_secret'] = $secretPlain
            $body = $p; $contentType = 'application/x-www-form-urlencoded'
        }
        'FormBodyWithScope' {
            $p = $Grant.Clone(); $p['client_id'] = $ClientId; $p['client_secret'] = $secretPlain; $p['scope'] = $scopeForm
            $body = $p; $contentType = 'application/x-www-form-urlencoded'
        }
        'FormBodyBasicAuth' {
            $p = $Grant.Clone(); $p['scope'] = $scopeForm
            $body = $p; $contentType = 'application/x-www-form-urlencoded'; $headers.Authorization = $basic
        }
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-WebRequest -Method Post -Uri $uri -Headers $headers -Body $body -ContentType $contentType -SkipHttpErrorCheck
    $sw.Stop()
    $json = $null; try { $json = $r.Content | ConvertFrom-Json } catch { }
    $status = [int]$r.StatusCode
    $errorText = if ($json.error) { "$($json.error): $($json.error_description)" }
             elseif ($status -ne 200) { $text = "$($r.Content)"; $text.Substring(0, [math]::Min(300, $text.Length)) }
    [pscustomobject]@{
        Style      = $Style
        GrantType  = $Grant.grant_type
        StatusCode = $status
        Success    = ($status -eq 200 -and $json.access_token)
        Ms         = $sw.ElapsedMilliseconds
        Error      = $errorText
        # BGL returns these alongside the token. is_new_token = false would mean BGL handed back an existing
        # token rather than issuing one, which changes how T03/T05 results should be read.
        IsNewToken            = $json.is_new_token
        AccessTokenExpiresAt  = $json.access_token_expires_at
        RefreshTokenExpiresAt = $json.refresh_token_expires_at
        Token      = $json
    }
}

$styles = if ($TestAllStyles) { 'BglDocumented', 'FormBody', 'FormBodyWithScope', 'FormBodyBasicAuth' } else { @($TokenStyle) }
$results = [System.Collections.Generic.List[object]]::new()
$goodToken = $null

foreach ($s in $styles) {
    Write-Host "=== Token exchange style: $s ===" -ForegroundColor Cyan
    $code = Get-AuthCode
    $r = Invoke-TokenRequest -Style $s -Grant @{ grant_type = 'authorization_code'; code = $code; redirect_uri = $RedirectUri }
    $results.Add($r)
    Write-Host ("{0}  HTTP {1}  {2}" -f ($(if ($r.Success) { 'SUCCESS' } else { 'FAILED ' })), $r.StatusCode, $r.Error)
    # Keep the newest token: each style needs a fresh consent, which may revoke tokens from earlier ones,
    # and the refresh tests (T05) must start from a token BGL still honours.
    if ($r.Success) { $goodToken = $r.Token }
}

$refreshResults = @()
if ($goodToken -and -not $SkipRefreshTest) {
    Write-Host "`n=== Refresh token tests ===" -ForegroundColor Cyan
    # refresh_token_expires_at is in whole seconds; wait so a sliding expiry can't look unchanged.
    Start-Sleep -Seconds 2
    $currentRefresh = $goodToken.refresh_token
    $previousRefresh = $null; $workingStyle = $null
    foreach ($s in $styles) {
        $r = Invoke-TokenRequest -Style $s -Grant @{ grant_type = 'refresh_token'; refresh_token = $currentRefresh }
        $rotated = [bool]($r.Success -and $r.Token.refresh_token -and ($r.Token.refresh_token -ne $currentRefresh))
        # Does refreshing push the refresh token's expiry out (sliding), or is the 30 days fixed from first
        # consent? A keep-alive flow only helps if it slides.
        # BGL documents refresh_token_expires_at on the code exchange but not on the refresh response, so a
        # missing field means "unknown", not "not extended".
        $expiryBefore = $goodToken.refresh_token_expires_at
        $expiryAfter = $r.Token.refresh_token_expires_at
        $deltaSeconds = if ($r.Success -and $expiryBefore -and $expiryAfter) { [long]$expiryAfter - [long]$expiryBefore }
        $extended = if (-not $r.Success) { $null }
                    elseif ($null -eq $deltaSeconds) { 'Unknown (refresh_token_expires_at not returned)' }
                    elseif ($deltaSeconds -gt 0) { 'Extended' } else { 'NotExtended' }
        $refreshResults += [pscustomobject]@{
            Test = 'refresh'; Style = $s; StatusCode = $r.StatusCode; Success = [bool]$r.Success; RefreshTokenRotated = $rotated
            RefreshExpiryBefore = $expiryBefore; RefreshExpiryAfter = $expiryAfter; RefreshExpiryDeltaSeconds = $deltaSeconds; RefreshExpiryExtended = $extended
            IsNewToken = $r.IsNewToken; Error = $r.Error
        }
        Write-Host ("{0}  HTTP {1}  rotated={2}  expiry={3}  {4}" -f ($(if ($r.Success) { 'SUCCESS' } else { 'FAILED ' })), $r.StatusCode, $rotated, $extended, $r.Error)
        if ($r.Success) {
            $goodToken = $r.Token; $workingStyle = $s
            if ($rotated) { $previousRefresh = $currentRefresh; $currentRefresh = $r.Token.refresh_token }
        }
    }
    # If BGL rotates refresh tokens: does the PREVIOUS one still work, and does reusing it revoke
    # the new one? This shows how fragile a shared connection would be.
    if ($previousRefresh -and $workingStyle) {
        $old = Invoke-TokenRequest -Style $workingStyle -Grant @{ grant_type = 'refresh_token'; refresh_token = $previousRefresh }
        $after = Invoke-TokenRequest -Style $workingStyle -Grant @{ grant_type = 'refresh_token'; refresh_token = $currentRefresh }
        $refreshResults += [pscustomobject]@{ Test = 'reuse-previous-refresh-token'; Style = $workingStyle; StatusCode = $old.StatusCode; Success = [bool]$old.Success; RefreshTokenRotated = $null; Error = $old.Error }
        $refreshResults += [pscustomobject]@{ Test = 'current-token-still-valid-after-reuse'; Style = $workingStyle; StatusCode = $after.StatusCode; Success = [bool]$after.Success; RefreshTokenRotated = $null; Error = $after.Error }
        Write-Host "Previous refresh token reusable: $([bool]$old.Success)   Current token still valid afterwards: $([bool]$after.Success)"
        if ($after.Success) { $goodToken = $after.Token }
        elseif ($old.Success) { $goodToken = $old.Token }
        else { Write-Warning 'Both refresh tokens rejected - BGL may revoke the token family on reuse. Re-run without -TestAllStyles to get a fresh token.' }
    }
}

$summary = [ordered]@{
    environment        = $Environment
    authorizeUrl       = $envCfg.AuthorizeUrl
    tokenUrl           = $envCfg.TokenUrl
    requestedScope     = $Scope
    exchangeResults    = $results | Select-Object Style, StatusCode, Success, Ms, IsNewToken, AccessTokenExpiresAt, RefreshTokenExpiresAt, Error
    refreshResults     = $refreshResults
    grantedScope       = $goodToken.scope
    expiresInSeconds   = $goodToken.expires_in
    refreshTokenExpiresAt = $goodToken.refresh_token_expires_at
    bglFirmId          = $goodToken.bgl_firm_id
    authorizedUsername = $goodToken.username
    tokenFieldNames    = if ($goodToken) { $goodToken.PSObject.Properties.Name } else { @() }
}
Write-SpikeResult -Data $summary -Name 'token-tests' | Out-Null

if ($goodToken) {
    $goodToken | Add-Member -NotePropertyName obtained_at_utc -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force
    Save-BglToken -Token $goodToken -Environment $Environment | Out-Null
    Write-Host "`nGranted scope: $($goodToken.scope)   Firm: $($goodToken.bgl_firm_id)   User: $($goodToken.username)" -ForegroundColor Green
}
else {
    Write-Host "`nNo token style succeeded. Check redirect URI registration, scope, and client secret." -ForegroundColor Red
    exit 1
}
