// identity.bicep

@description('RESOURCE LOCATION.')
param location string

@description('NAMING PREFIX.')
param namingPrefix string

@description('TAGS.')
param tags object

@description('STORAGE ACCOUNT NAME.')
param storageAccountName string

// var Role Definition Id
var varRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')

// User Assigned Managed Identity
resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namingPrefix}-vmssUserAssignedIdentity'
  tags: tags
  location: location
}

// Storage Account using existing
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

// Role Assignment
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, userAssignedIdentity.id, varRoleDefinitionId)
  scope: storageAccount
  properties: {
    principalType: 'ServicePrincipal'
    principalId: userAssignedIdentity.properties.principalId
    roleDefinitionId: varRoleDefinitionId
  }
}

// Outputs
output uamiId string = userAssignedIdentity.id
output clientId string = userAssignedIdentity.properties.clientId
