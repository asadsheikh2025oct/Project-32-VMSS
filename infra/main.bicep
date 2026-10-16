// main.bicep
targetScope = 'resourceGroup'

@description('RESOURCE LOCATION.')
param location string = resourceGroup().location

@description('NAMING PREFIX')
param namingPrefix string

@description('TAG')
param tags object

@description('VNET NAME.')
param vnetName string

@description('VNET ADDRESS SPACE.')
param vnetAddressSpace string

@description('SUBNET NAME.')
param subnetName string

@description('SUBNET ADDRESS PREFIX.')
param subnetAddressPrefix string

@description('CONTAINER NAME.')
param storageContainerName string

@description('DEPLOY VMSS - Set true after app files have been upload to blob container.')
param deployVmss bool

@description('VM PUBLIC KEY.')
@secure()
param vmPublicKey string

@description('VM ADMIN USERNAME.')
param vmAdminUsername string

@description('VM INSTANCE COUNT.')
param vmInstanceCount int

@description('VM SIZE.')
param vmSize string

//-------------------------------------------------------------------------

// NSG + VNET + SUBNET
module vnetModule './modules/network.bicep' = {
  params: {
    location: location
    namingPrefix: namingPrefix
    subnetAddressPrefix: subnetAddressPrefix
    subnetName: subnetName
    tags: tags
    vnetAddressSpace: vnetAddressSpace
    vnetName: vnetName
  }
}

// Deploy Load Balancer
module loadBalancerModule './modules/loadBalancer.bicep' = {
  params: {
    location: location
    tags: tags
    namingPrefix: namingPrefix
  }
}

// Deploy Storage Account
module storageModule './modules/storage.bicep' = {
  params: {
    location: location
    tags: tags
    containerName: storageContainerName
    namingPrefix: namingPrefix
  }
}

// Deploy Identity
module identityModule './modules/identity.bicep' = {
  params: {
    location: location
    tags: tags
    namingPrefix: namingPrefix
    storageAccountName: storageModule.outputs.storageAccountName
  }
}

// Deploy vmss
module vmssModule './modules/vmss.bicep' = if (deployVmss) {
  params: {
    location: location
    tags: tags
    backendPoolId: loadBalancerModule.outputs.lbBackendAddressPoolId
    blobContainerName: storageModule.outputs.storageContainerName
    blobEndpoint: storageModule.outputs.blobEndpoint
    namingPrefix: namingPrefix
    subnetId: vnetModule.outputs.subnetId
    uamiClientId: identityModule.outputs.clientId
    uamiId: identityModule.outputs.uamiId
    vmAdminPublicKey: vmPublicKey
    vmAdminUsername: vmAdminUsername
    vmInstanceCount: vmInstanceCount
    vmSize: vmSize
  }
}

// Autoscale
module autoscaleModule './modules/autoscale.bicep' = if (deployVmss) {
  params: {
    location: location
    tags: tags
    defaultCapacity: '2'
    maxCapacity: '4'
    minCapacity: '2'
    namingPrefix: namingPrefix
    vmssId: vmssModule!.outputs.vmssId
  }
}

// Outputs
output subnetId string = vnetModule.outputs.subnetId
output publicIpAddress string = loadBalancerModule.outputs.publicIpAddress
output lbBackendAddressPoolId string = loadBalancerModule.outputs.lbBackendAddressPoolId
output storageAccountName string = storageModule.outputs.storageAccountName
output blobStorageContainerName string = storageModule.outputs.storageContainerName
output blobEndpoint string = storageModule.outputs.blobEndpoint
output uamiId string = identityModule.outputs.uamiId
output clientId string = identityModule.outputs.clientId
output vmssName string = deployVmss ? vmssModule!.outputs.vmssName : ''
output autoscaleId string = deployVmss ? autoscaleModule!.outputs.autoscaleId : ''
output autoscaleName string = deployVmss ? autoscaleModule!.outputs.autoscaleName : ''
