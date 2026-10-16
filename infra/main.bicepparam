using './main.bicep'

param namingPrefix = 'prj32'
param tags = {
  project: 'project32-VMSS'
  createdby: 'ais'
}
param vnetName = 'vnet'
param vnetAddressSpace = '10.0.0.0/16'
param subnetName = 'vm-subnet'
param subnetAddressPrefix = '10.0.1.0/24'
param storageContainerName = 'webapp'
param deployVmss = true
param vmAdminUsername = 'azureuser'
param vmInstanceCount = 2
param vmSize = 'Standard_B1s'
param vmPublicKey = loadTextContent('./project30_key.pub')
