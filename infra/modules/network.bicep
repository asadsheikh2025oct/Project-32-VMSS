// network.bicep

@description('NAMING PREFIX.')
param namingPrefix string

@description('RESOURCE LOCATION.')
param location string

@description('VIRTUAL NETWORK NAME.')
param vnetName string

@description('VIRTUAL NETWORK ADDRESS SPACE.')
param vnetAddressSpace string

@description('SUBNET NAME.')
param subnetName string

@description('SUBNET ADDRESS PREFIX.')
param subnetAddressPrefix string

@description('PROJECT 32 TAG.')
param tags object

// NSG
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${namingPrefix}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: '${namingPrefix}-nsg-rule01'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
          protocol: 'Tcp'
          description: 'Allow inbound traffic from internet on port 80'
          destinationAddressPrefix: subnetAddressPrefix
          destinationPortRange: '80'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
        }
      }
    ]
  }
}

// VIRTUAL NETWORK WITH 1 SUBNET
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${namingPrefix}-${vnetName}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressSpace
      ]
    }
    subnets: [
      {
        name: '${namingPrefix}-${subnetName}'
        properties: {
          addressPrefix: subnetAddressPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

// Outputs
output vnetId string = vnet.id
output subnetId string = vnet.properties.subnets[0].id
output nsgId string = nsg.id
