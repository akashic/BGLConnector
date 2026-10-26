param location string
param tags object
param storageAccountName string
param deploymentContainerName string
param eventTableName string

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    // Keys are disabled; the function app uses its managed identity for every storage operation.
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Enabled'
  }

  resource blobService 'blobServices' = {
    name: 'default'

    resource deploymentContainer 'containers' = {
      name: deploymentContainerName
    }
  }

  // Event IDs already handled, so BGL retries and replays are processed once.
  resource tableService 'tableServices' = {
    name: 'default'

    resource eventTable 'tables' = {
      name: eventTableName
    }
  }
}

output name string = storage.name
output blobEndpoint string = storage.properties.primaryEndpoints.blob
