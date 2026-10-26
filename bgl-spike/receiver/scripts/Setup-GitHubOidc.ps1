#Requires -Version 7.2
<#
.SYNOPSIS
    Creates the deployment identity GitHub Actions uses for the BGL webhook receiver (OIDC, no stored secrets) and
    grants it least-privilege access to the resource group. Safe to re-run.

.DESCRIPTION
    - Creates the resource group if it doesn't exist.
    - Creates a user-assigned managed identity with a federated credential trusted only for
      <subject prefix>:environment:<env>, so only jobs running in that GitHub environment can deploy. The prefix is
      read from the repo's OIDC settings, so it matches whether GitHub issues the name-based subject
      (repo:<owner>/<repo>) or the immutable one (repo:<owner>@<owner-id>/<repo>@<repo-id>).
    - Grants it, on the resource group only:
        * Contributor
        * Role Based Access Control Administrator, constrained by an ABAC condition so it can ONLY assign the three
          roles the function app needs (infra/modules/functionApp.bicep), and only to service principals.
    - Grants the person who sets the Key Vault secrets (default: you) Key Vault Secrets Officer on the resource group.
      The pipeline never sees secret values.
    - Optionally (-SetGitHubVariables) creates the GitHub environment, protects it and writes its variables with the gh
      CLI. Protection matters because the identity can deploy code that runs as the function app, which can read every
      Key Vault secret: only -DeployBranch may deploy, and -Reviewer (default: you) approves each run.

    Requires the Azure CLI signed in as Owner (or User Access Administrator + Contributor) on the subscription or
    resource group, and the gh CLI signed in with access to the repo (or pass -OidcSubjectPrefix).
    -WhatIf shows the changes without making them.

.EXAMPLE
    ./Setup-GitHubOidc.ps1 -SubscriptionId 0000... -ResourceGroup rg-bglhook-dev -GitHubRepository <owner>/<repo> -SetGitHubVariables
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $Location = 'australiaeast',
    [Parameter(Mandatory)] [ValidatePattern('^[^/]+/[^/]+$')] [string] $GitHubRepository,
    [ValidateSet('dev', 'test', 'prod')] [string] $GitHubEnvironment = 'dev',
    [string] $IdentityName = "id-github-bglhook-$GitHubEnvironment",

    # Subject prefix GitHub puts in the OIDC token. Read from the repo's settings with gh when omitted.
    [ValidatePattern('^repo:')] [string] $OidcSubjectPrefix,

    # Object ID of the person who will set the Key Vault secrets. Default: the signed-in Azure CLI user.
    [string] $SecretsOfficerObjectId,

    [switch] $SetGitHubVariables,

    # With -SetGitHubVariables: the GitHub user who approves deployments (default: the gh user) and the only branch
    # allowed to deploy.
    [string] $Reviewer,
    [string] $DeployBranch = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# Roles the Bicep template assigns to the function app's managed identity (infra/modules/functionApp.bicep).
$AssignableRoles = @(
    'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' # Storage Blob Data Owner
    '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' # Storage Table Data Contributor
    '4633458b-17de-408a-b874-0445c86b69e6' # Key Vault Secrets User
) -join ', '

az account set --subscription $SubscriptionId
$tenantId = az account show --query tenantId -o tsv

if ((az group exists -n $ResourceGroup) -ne 'true') {
    if (-not $PSCmdlet.ShouldProcess($ResourceGroup, 'Create resource group')) {
        Write-Host 'The remaining steps need the resource group, so the preview stops here.'
        return
    }
    az group create -n $ResourceGroup -l $Location --only-show-errors | Out-Null
}
$rgId = az group show -n $ResourceGroup --query id -o tsv

$identity = az identity list -g $ResourceGroup --query "[?name=='$IdentityName'] | [0]" --only-show-errors | ConvertFrom-Json
if (-not $identity) {
    if (-not $PSCmdlet.ShouldProcess($IdentityName, 'Create managed identity')) {
        Write-Host 'The remaining steps need the identity, so the preview stops here.'
        return
    }
    Write-Host "Creating managed identity $IdentityName"
    $identity = az identity create -g $ResourceGroup -n $IdentityName -l $Location --only-show-errors | ConvertFrom-Json
}

# The subject GitHub issues depends on the repo's OIDC settings: name-based (repo:owner/repo) or immutable
# (repo:owner@id/repo@id). Entra matches it exactly.
function Get-OidcSubjectPrefix {
    try { $sub = gh api "repos/$GitHubRepository/actions/oidc/customization/sub" | ConvertFrom-Json }
    catch { throw "Couldn't read the OIDC subject settings of $GitHubRepository with gh ($_). Sign in with 'gh auth login', or pass -OidcSubjectPrefix." }
    if (-not $sub.use_default) {
        throw "$GitHubRepository uses a custom OIDC subject template. Create the federated credential by hand, matching the sub claim it produces."
    }
    if ($sub.PSObject.Properties['sub_claim_prefix'] -and $sub.sub_claim_prefix) { return $sub.sub_claim_prefix }
    if (-not ($sub.PSObject.Properties['use_immutable_subject'] -and $sub.use_immutable_subject)) { return "repo:$GitHubRepository" }
    $repo = gh api "repos/$GitHubRepository" | ConvertFrom-Json
    return "repo:$($repo.owner.login)@$($repo.owner.id)/$($repo.name)@$($repo.id)"
}

if (-not $OidcSubjectPrefix) { $OidcSubjectPrefix = Get-OidcSubjectPrefix }
$subject = "$($OidcSubjectPrefix):environment:$GitHubEnvironment"
$fedName = "github-$GitHubEnvironment"
$fedArgs = @('-g', $ResourceGroup, '--identity-name', $IdentityName, '--only-show-errors')
$creds = @(az identity federated-credential list @fedArgs | ConvertFrom-Json)
if (-not ($creds | Where-Object subject -ceq $subject)) {
    if ($creds | Where-Object name -eq $fedName) {
        throw "Federated credential '$fedName' exists with a different subject. Delete it or check -GitHubRepository."
    }
    if ($PSCmdlet.ShouldProcess($subject, 'Add federated credential')) {
        az identity federated-credential create @fedArgs --name $fedName --issuer 'https://token.actions.githubusercontent.com' `
            --subject $subject --audiences 'api://AzureADTokenExchange' | Out-Null
    }
}

function Grant-Role {
    param([string] $Role, [string] $PrincipalId, [string] $PrincipalType, [string] $Condition)
    $existing = az role assignment list --assignee $PrincipalId --scope $rgId --role $Role --query '[].id' -o tsv
    if ($existing) { Write-Host "Already has '$Role' on $ResourceGroup"; return }
    if (-not $PSCmdlet.ShouldProcess($ResourceGroup, "Grant '$Role' to $PrincipalId")) { return }
    Write-Host "Granting '$Role' on $ResourceGroup"
    $roleArgs = @('role', 'assignment', 'create', '--assignee-object-id', $PrincipalId,
        '--assignee-principal-type', $PrincipalType, '--role', $Role, '--scope', $rgId, '--only-show-errors')
    if ($Condition) { $roleArgs += @('--condition', $Condition, '--condition-version', '2.0') }
    az @roleArgs | Out-Null
}

Grant-Role 'Contributor' $identity.principalId 'ServicePrincipal'

# Constrained delegation: may only create/delete assignments of the listed roles, to service principals.
$condition = @"
((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$AssignableRoles} AND @Request[Microsoft.Authorization/roleAssignments:PrincipalType] StringEqualsIgnoreCase 'ServicePrincipal')) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$AssignableRoles}))
"@
Grant-Role 'Role Based Access Control Administrator' $identity.principalId 'ServicePrincipal' $condition

# Whoever sets the secrets needs data-plane access; Owner and Contributor don't include it under the RBAC model.
if (-not $SecretsOfficerObjectId) { $SecretsOfficerObjectId = az ad signed-in-user show --query id -o tsv }
Grant-Role 'Key Vault Secrets Officer' $SecretsOfficerObjectId 'User'

$vars = [ordered]@{
    AZURE_CLIENT_ID       = $identity.clientId
    AZURE_TENANT_ID       = $tenantId
    AZURE_SUBSCRIPTION_ID = $SubscriptionId
    AZURE_RESOURCE_GROUP  = $ResourceGroup
}

if ($SetGitHubVariables -and $PSCmdlet.ShouldProcess("$GitHubRepository environment '$GitHubEnvironment'", 'Protect and set variables')) {
    # The federated credential trusts any job in this environment, from any branch, so the environment's own rules are
    # what stop a pushed branch with an edited workflow from deploying. Self-review stays allowed, so a sole
    # maintainer can approve their own runs.
    $reviewerId = if ($Reviewer) { gh api "users/$Reviewer" --jq .id } else { gh api user --jq .id }
    @{
        reviewers                = @(@{ type = 'User'; id = [int64]$reviewerId })
        deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }
    } | ConvertTo-Json -Depth 4 | gh api --method PUT "repos/$GitHubRepository/environments/$GitHubEnvironment" --input - --silent

    $policyUrl = "repos/$GitHubRepository/environments/$GitHubEnvironment/deployment-branch-policies"
    $policies = gh api $policyUrl | ConvertFrom-Json
    if (-not ($policies.branch_policies | Where-Object { $_.name -eq $DeployBranch -and $_.type -eq 'branch' })) {
        gh api --method POST $policyUrl -f name=$DeployBranch -f type=branch --silent
    }

    foreach ($kv in $vars.GetEnumerator()) {
        gh variable set $kv.Key --env $GitHubEnvironment --repo $GitHubRepository --body $kv.Value
    }
    Write-Host "GitHub environment '$GitHubEnvironment': deploys from '$DeployBranch' only, each approved by $(if ($Reviewer) { $Reviewer } else { 'you' }); variables set." -ForegroundColor Green
}
elseif (-not $SetGitHubVariables) {
    Write-Host "`nCreate GitHub environment '$GitHubEnvironment' with a required reviewer and deployment branches limited to '$DeployBranch'," -ForegroundColor Green
    Write-Host "then add these environment variables (identifiers, not secrets):" -ForegroundColor Green
    $vars | Format-Table -HideTableHeaders | Out-String | Write-Host
}
