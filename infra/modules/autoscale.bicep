// autoscale.bicep
@description('RESOURCE LOCATION.')
param location string

@description('NAMING PREFIX.')
param namingPrefix string

@description('TAGS.')
param tags object

@description('VMSS ID.')
param vmssId string

@description('MINIMUM CAPACITY.')
param minCapacity string

@description('MAX CAPACITY.')
param maxCapacity string

@description('DEFAULT CAPACITY.')
param defaultCapacity string

//------------------------------------------------------------------------

// autoscale
resource autoscale 'Microsoft.Insights/autoscalesettings@2022-10-01' = {
  name: '${namingPrefix}-autoscale-settings'
  location: location
  tags: tags
  properties: {
    enabled: true
    targetResourceUri: vmssId
    profiles: [
      {
        name: 'autoscale-config'
        capacity: {
          default: defaultCapacity
          maximum: maxCapacity
          minimum: minCapacity
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: vmssId
              operator: 'LessThan'
              statistic: 'Average'
              threshold: 30
              timeAggregation: 'Average'
              timeGrain: 'PT1M'
              timeWindow: 'PT5M'
            }
            scaleAction: {
              cooldown: 'PT5M'
              direction: 'Decrease'
              type: 'ChangeCount'
              value: '1'
            }
          }
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: vmssId
              operator: 'GreaterThan'
              statistic: 'Average'
              threshold: 70
              timeAggregation: 'Average'
              timeGrain: 'PT1M'
              timeWindow: 'PT5M'
            }
            scaleAction: {
              cooldown: 'PT5M'
              direction: 'Increase'
              type: 'ChangeCount'
              value: '1'
            }
          }
        ]
      }
    ]
  }
}

// Outputs
output autoscaleId string = autoscale.id
output autoscaleName string = autoscale.name
