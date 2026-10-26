// BGL webhook receiver: an Azure Function that verifies BGL's signed webhooks (the SF360 Audit event) and hands them
// to a Power Automate flow. Deploys into an existing resource group.
targetScope = 'resourceGroup'

// ---------- Naming & placement ----------

@description('Short workload name used in resource names (lowercase letters and digits).')
@minLength(3)
@maxLength(10)
param workload string = 'bglhook'

@description('Environment name, e.g. dev, test, prod.')
@allowed(['dev', 'test', 'prod'])
param environmentName string

@description('Azure region. Must support the Flex Consumption plan (az functionapp list-flexconsumption-locations).')
param location string = resourceGroup().location

@description('Tags applied to every resource.')
param tags object = {}

// ---------- Receiver ----------

@description('When set, the client code in BGL\'s Authorization header must match (compared in lowercase). Leave empty until T12 shows the code BGL sends.')
param expectedClientCode string = ''

@description('Allowed clock skew between BGL\'s timestamp and now, in seconds either side. 0 disables the check.')
@minValue(0)
@maxValue(3600)
param maxSkewSeconds int = 300

@description('Spike only: return rejection reasons in responses so the webhook simulator can report them. Keep false for real traffic.')
param exposeRejectionReason bool = false

@description('Inbound IP allow-list (CIDR, e.g. 203.0.113.0/24). Empty = reachable from anywhere, protected by the function key and BGL\'s signature. Fill in from BGL\'s source IP ranges (open question 6) when known.')
param allowedIpRanges array = []

// ---------- Scale ----------

@description('Instance memory in MB. 512 is ample.')
@allowed([512, 2048, 4096])
param instanceMemoryMB int = 512

@description('Maximum instances. Microsoft advises at least 40 for HTTP apps: below that, bursts beyond capacity are rejected by the platform before reaching the code.')
@minValue(40)
@maxValue(1000)
param maximumInstanceCount int = 40

// ---------- Names ----------

var suffix = take(uniqueString(resourceGroup().id, workload, environmentName), 6)
var baseName = '${workload}-${environmentName}-${suffix}'
var names = {
  storage: take('st${replace(workload, '-', '')}${environmentName}${suffix}', 24)
  keyVault: take('kv-${baseName}', 24)
  plan: 'asp-${baseName}'
  functionApp: 'func-${baseName}'
}
var allTags = union(tags, {
  workload: workload
  environment: environmentName
})
var deploymentContainerName = 'app-package'
var eventTableName = 'BglEvents'

module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    tags: allTags
    storageAccountName: names.storage
    deploymentContainerName: deploymentContainerName
    eventTableName: eventTableName
  }
}

module keyVault 'modules/keyVault.bicep' = {
  name: 'keyVault'
  params: {
    location: location
    tags: allTags
    keyVaultName: names.keyVault
  }
}

module functionApp 'modules/functionApp.bicep' = {
  name: 'functionApp'
  params: {
    location: location
    tags: allTags
    planName: names.plan
    functionAppName: names.functionApp
    storageAccountName: storage.outputs.name
    deploymentContainerUrl: '${storage.outputs.blobEndpoint}${deploymentContainerName}'
    keyVaultName: keyVault.outputs.name
    eventTableName: eventTableName
    instanceMemoryMB: instanceMemoryMB
    maximumInstanceCount: maximumInstanceCount
    expectedClientCode: expectedClientCode
    maxSkewSeconds: maxSkewSeconds
    exposeRejectionReason: exposeRejectionReason
    allowedIpRanges: allowedIpRanges
  }
}

output functionAppName string = functionApp.outputs.name
output functionAppHostName string = functionApp.outputs.defaultHostName
@description('Register this URL with BGL after appending ?code=<function key> (see the runbook, Part D).')
output receiverBaseUrl string = functionApp.outputs.receiverBaseUrl
output keyVaultName string = keyVault.outputs.name
