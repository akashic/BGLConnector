param location string
param tags object
param keyVaultName string

// Holds bgl-webhook-secret, audit-forward-url and error-report-url. The two URLs are Power Automate trigger URLs, whose
// sig makes them credentials. Values are set by a person (runbook Part D), never by the template or the pipeline.
resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

output name string = vault.name
