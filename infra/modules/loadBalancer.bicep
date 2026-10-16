// loadBalancer.bicep

@description('RESOURCE LOCATION.')
param location string

@description('NAMING PREFIX.')
param namingPrefix string

@description('TAGS.')
param tags object

// Variables
var varLoadBalancerName = '${namingPrefix}-lb'
var varFrontEndName = '${namingPrefix}-fe-web'
var varBackEndName = '${namingPrefix}-be-web'
var varHealthProbeName = '${namingPrefix}-health-probe-http'

// Public IP
resource publicIP 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${namingPrefix}-publicIP'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

// Load Balancer
resource loadBalancer 'Microsoft.Network/loadBalancers@2023-11-01' = {
  name: varLoadBalancerName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    backendAddressPools: [
      {
        name: varBackEndName
      }
    ]
    frontendIPConfigurations: [
      {
        name: varFrontEndName
        properties: {
          publicIPAddress: {
            id: publicIP.id
          }
        }
      }
    ]
    probes: [
      {
        name: varHealthProbeName
        properties: {
          port: 80
          protocol: 'Http'
          intervalInSeconds: 15
          numberOfProbes: 2
          requestPath: '/'
        }
      }
    ]
    loadBalancingRules: [
      {
        name: '${varLoadBalancerName}-rules-http'
        properties: {
          frontendPort: 80
          protocol: 'Tcp'
          backendPort: 80
          disableOutboundSnat: true
          idleTimeoutInMinutes: 4
          enableFloatingIP: false
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', varLoadBalancerName, varBackEndName)
          }
          frontendIPConfiguration: {
            id: resourceId(
              'Microsoft.Network/loadBalancers/frontendIPConfigurations',
              varLoadBalancerName,
              varFrontEndName
            )
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', varLoadBalancerName, varHealthProbeName)
          }
        }
      }
    ]
    outboundRules: [
      {
        name: '${varLoadBalancerName}-outbound-rule'
        properties: {
          idleTimeoutInMinutes: 4
          allocatedOutboundPorts: 8000
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', varLoadBalancerName, varBackEndName)
          }
          frontendIPConfigurations: [
            {
              id: resourceId(
                'Microsoft.Network/loadBalancers/frontendIPConfigurations',
                varLoadBalancerName,
                varFrontEndName
              )
            }
          ]
          protocol: 'All'
          enableTcpReset: true
        }
      }
    ]
  }
}

// Outputs
output publicIpId string = publicIP.id
output publicIpAddress string = publicIP.properties.ipAddress
output loadBalancerId string = loadBalancer.id
output loadBalancerName string = loadBalancer.name
output lbBackendAddressPoolId string = loadBalancer.properties.backendAddressPools[0].id
output lbFrontEndIpConfigurationId string = loadBalancer.properties.frontendIPConfigurations[0].id
output lbProbeId string = loadBalancer.properties.probes[0].id
