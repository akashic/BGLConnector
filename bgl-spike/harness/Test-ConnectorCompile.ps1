#Requires -Version 7.0
<#
.SYNOPSIS
  Offline compile check for both connector scripts. Needs the .NET SDK. Exit code 0 = both build.

.DESCRIPTION
  Power Platform reports a compile failure in custom code only as an internal server error when the
  connector is saved. This builds connector/script.csx and connector/script-with-proxy.csx locally
  against Microsoft's documented supporting classes (compile-check/Stubs.cs), so syntax and type
  errors show up before deployment.

  The .csx files have no using directives because the platform supplies them, so each script is
  wrapped with Microsoft's list of supported namespaces and written to compile-check/generated/.

  The first run downloads NuGet packages, so it needs network access. Later runs work offline.

  This cannot catch what only the real sandbox enforces at runtime, or differences in the real
  signatures of the undocumented members the proxy variant uses. Deploying to a dev environment is
  still the final check.

.EXAMPLE
  ./Test-ConnectorCompile.ps1
#>
$ErrorActionPreference = 'Stop'

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Host 'The .NET SDK is required. Mac: brew install dotnet. Windows: winget install Microsoft.DotNet.SDK.8' -ForegroundColor Red
    exit 1
}

$root = Split-Path $PSScriptRoot -Parent
$project = Join-Path $root 'compile-check'
$generated = Join-Path $project 'generated'
New-Item -ItemType Directory -Path $generated -Force | Out-Null

# Supported namespaces, from Microsoft Learn "Use custom code in a custom connector".
$usings = @(
    'System', 'System.Collections', 'System.Collections.Generic', 'System.Diagnostics', 'System.IO',
    'System.IO.Compression', 'System.Linq', 'System.Net', 'System.Net.Http', 'System.Net.Http.Headers',
    'System.Net.Security', 'System.Security.Authentication', 'System.Security.Cryptography', 'System.Text',
    'System.Text.RegularExpressions', 'System.Threading', 'System.Threading.Tasks', 'System.Web', 'System.Xml',
    'System.Xml.Linq', 'System.Drawing', 'System.Drawing.Drawing2D', 'System.Drawing.Imaging',
    'Microsoft.Extensions.Logging', 'Newtonsoft.Json', 'Newtonsoft.Json.Linq'
) | ForEach-Object { "using $_;" }

$variants = 'script', 'script-with-proxy'
foreach ($v in $variants) {
    $source = Get-Content (Join-Path $root "connector/$v.csx") -Raw
    # #line keeps compiler error locations pointing at the original .csx line numbers.
    $wrapped = ($usings -join "`n") + "`n#line 1 `"$v.csx`"`n" + $source
    Set-Content -Path (Join-Path $generated "$v.g.cs") -Value $wrapped -Encoding utf8
}

$csproj = Join-Path $project 'CompileCheck.csproj'
dotnet restore $csproj -v quiet | Out-Null
if ($LASTEXITCODE) { Write-Host 'NuGet restore failed (the first run needs network access).' -ForegroundColor Red; exit 1 }

$failed = 0
foreach ($v in $variants) {
    $output = dotnet build $csproj --no-restore -nologo -v quiet "-p:ScriptVariant=$v" 2>&1
    if ($LASTEXITCODE) {
        Write-Host "FAIL  connector/$v.csx" -ForegroundColor Red
        $output | Where-Object { $_ -match ': (error|warning) ' } | Sort-Object -Unique | ForEach-Object { Write-Host "      $_" }
        $failed++
    }
    else { Write-Host "PASS  connector/$v.csx compiles" -ForegroundColor Green }
}
Write-Host ''
if ($failed) { Write-Host "$failed script(s) failed to compile" -ForegroundColor Red; exit 1 }
Write-Host 'Both connector scripts compile' -ForegroundColor Green
exit 0
