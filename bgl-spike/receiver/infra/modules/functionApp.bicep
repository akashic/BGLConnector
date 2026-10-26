param location string
param tags object
param planName string
param functionAppName string
param storageAccountName string
param deploymentContainerUrl string
param keyVaultName string
param eventTableName string
param instanceMemoryMB int
param maximumInstanceCount int
param expectedClientCode string
param maxSkewSeconds int
param exposeRejectionReason bool
param allowedIpRanges array

// Built-in role definition IDs. Keep in step with $AssignableRoles in scripts/Setup-GitHubOidc.ps1, which limits the
// pipeline to assigning exactly these.
var roles = {
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  storageTableDataContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
}

// Unresolved references reach the app as the literal text, which it treats as unset (ConfiguredValue.IsSet).
var kvRef = '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName='

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true // Linux
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    siteConfig: {
      minTlsVersion: '1.2'
      http20Enabled: true
      // With entries, everything else is denied. The deployment (scm) site keeps its own, open rules, so the pipeline
      // and a laptop can still deploy; the health check is on the main site, so a runner outside the list can't reach it.
      ipSecurityRestrictions: [
        for (cidr, i) in allowedIpRanges: {
          name: 'bgl-${i}'
          ipAddress: cidr
          action: 'Allow'
          priority: 100 + i
        }
      ]
      ipSecurityRestrictionsDefaultAction: empty(allowedIpRanges) ? 'Allow' : 'Deny'
      scmIpSecurityRestrictionsUseMain: false
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: deploymentContainerUrl
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: instanceMemoryMB
        maximumInstanceCount: maximumInstanceCount
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
    }
  }
}

// Disable basic-auth publishing credentials; deployments use Entra ID only.
resource ftpPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: functionApp
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource scmPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: functionApp
  name: 'scm'
  properties: {
    allow: false
  }
}

// Blob Data Owner is the documented minimum for AzureWebJobsStorage (host keys, leases, deployment package).
// Table Data Contributor covers the BglEvents table.
resource storageRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in [roles.storageBlobDataOwner, roles.storageTableDataContributor]: {
    name: guid(storage.id, functionApp.id, roleId)
    scope: storage
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
      principalId: functionApp.identity.principalId
      principalType: 'ServicePrincipal'
    }
  }
]

resource secretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, functionApp.id, roles.keyVaultSecretsUser)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsUser)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// A separate resource so the receiver URL can use the app's actual host name (Flex host names aren't predictable).
// It replaces all app settings on every deployment, so every setting the app needs belongs here.
resource appSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: functionApp
  name: 'appsettings'
  dependsOn: [storageRoleAssignments, secretsUser]
  properties: {
    // Host storage over managed identity (no connection strings or keys). No queue service: this app has HTTP triggers only.
    AzureWebJobsStorage__credential: 'managedidentity'
    AzureWebJobsStorage__blobServiceUri: storage.properties.primaryEndpoints.blob
    AzureWebJobsStorage__tableServiceUri: storage.properties.primaryEndpoints.table
    Bgl__ReceiverBaseUrl: 'https://${functionApp.properties.defaultHostName}/api/bgl/webhook'
    Bgl__WebhookSecret: '${kvRef}bgl-webhook-secret)'
    Bgl__AuditForwardUrl: '${kvRef}audit-forward-url)'
    Bgl__ErrorReportUrl: '${kvRef}error-report-url)'
    Bgl__ExpectedClientCode: expectedClientCode
    Bgl__MaxSkewSeconds: string(maxSkewSeconds)
    Bgl__ExposeRejectionReason: string(exposeRejectionReason)
    Bgl__EventTableName: eventTableName
  }
}

output name string = functionApp.name
output defaultHostName string = functionApp.properties.defaultHostName
output receiverBaseUrl string = 'https://${functionApp.properties.defaultHostName}/api/bgl/webhook'
output principalId string = functionApp.identity.principalId
