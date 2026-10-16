// vmss.bicep

@description('RESOURCE LOCATION.')
param location string

@description('NAMING PREFIX.')
param namingPrefix string

@description('TAGS.')
param tags object

@description('SUBNET ID.')
param subnetId string

@description('BACKEND POOL ID.')
param backendPoolId string

@description('USER ASSIGNED MANAGED IDENTITY ID.')
param uamiId string

@description('USER ASSIGNED MANAGED IDENTITY CLIENT ID.')
param uamiClientId string

@description('VM SIZE.')
param vmSize string = 'Standard_B1s'

@description('NUMBER OF VM INSTANCES.')
param vmInstanceCount int

@description('VM ADMIN USERNAME.')
param vmAdminUsername string

@description('VM ADMIN PUBLIC KEY.')
@secure()
param vmAdminPublicKey string

@description('BLOB ENDPOINT.')
param blobEndpoint string

@description('BLOB CONTAINER NAME.')
param blobContainerName string

// Variables
var varFileUri = '${blobEndpoint}${blobContainerName}/index.html'

// VMSS
resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2023-09-01' = {
  name: '${namingPrefix}-vmss'
  location: location
  tags: tags
  sku: {
    capacity: vmInstanceCount
    name: vmSize
    tier: 'Standard'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uamiId}': {}
    }
  }
  properties: {
    orchestrationMode: 'Uniform'
    upgradePolicy: {
      mode: 'Automatic'
    }
    virtualMachineProfile: {
      extensionProfile: {
        extensions: [
          {
            name: 'InstallWebApp'
            properties: {
              publisher: 'Microsoft.Azure.Extensions'
              type: 'CustomScript'
              typeHandlerVersion: '2.1'
              autoUpgradeMinorVersion: true
              protectedSettings: {
                commandToExecute: 'cloud-init status --wait && apt-get update && apt-get install -y nginx && cp index.html /var/www/html/index.html && chmod 644 /var/www/html/index.html && sed -i "s|__HOSTNAME__|$(hostname)|g" /var/www/html/index.html && sed -i "s|__TIMESTAMP__|$(date)|g" /var/www/html/index.html && systemctl enable nginx && systemctl restart nginx'
                managedIdentity: {
                  clientId: uamiClientId
                }
              }
              settings: {
                fileUris: [
                  varFileUri
                ]
              }
            }
          }
        ]
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: '${namingPrefix}-vmss-niconfig'
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: '${namingPrefix}-vmss-ipconfig'
                  properties: {
                    loadBalancerBackendAddressPools: [
                      {
                        id: backendPoolId
                      }
                    ]
                    subnet: {
                      id: subnetId
                    }
                  }
                }
              ]
            }
          }
        ]
      }
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: '0001-com-ubuntu-server-jammy'
          sku: '22_04-lts-gen2'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadWrite'
          managedDisk: {
            storageAccountType: 'Standard_LRS'
          }
        }
      }
      osProfile: {
        computerNamePrefix: 'p32vm'
        adminUsername: vmAdminUsername
        linuxConfiguration: {
          disablePasswordAuthentication: true
          ssh: {
            publicKeys: [
              {
                path: '/home/${vmAdminUsername}/.ssh/authorized_keys'
                keyData: vmAdminPublicKey
              }
            ]
          }
        }
      }
    }
  }
}

// Outputs
output vmssId string = vmss.id
output vmssName string = vmss.name
