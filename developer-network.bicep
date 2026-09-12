targetScope = 'resourceGroup'

param location string = resourceGroup().location
param developerSlug string
param addressPrefix string
param subnetPrefix string
param hubAddressPrefix string = '10.0.0.0/16'
param jumpPrivateIp string = '10.0.0.4'
param tags object = {
  project: 'techsprint'
  environment: 'testing'
}

var vnetName = 'vnet-ts-${developerSlug}-test'
var subnetName = 'snet-ts-${developerSlug}-app'
var asgName = 'asg-ts-${developerSlug}-app'
var nsgName = 'nsg-ts-${developerSlug}-app'
var routeTableName = 'rt-ts-${developerSlug}-test'

resource asg 'Microsoft.Network/applicationSecurityGroups@2023-09-01' = {
  name: asgName
  location: location
  tags: tags
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-From-Hub'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: hubAddressPrefix
          destinationApplicationSecurityGroups: [
            {
              id: asg.id
            }
          ]
        }
      }
      {
        name: 'Allow-HTTP-From-Hub'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: hubAddressPrefix
          destinationApplicationSecurityGroups: [
            {
              id: asg.id
            }
          ]
        }
      }
      {
        name: 'Allow-LB-Probe'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationApplicationSecurityGroups: [
            {
              id: asg.id
            }
          ]
        }
      }
    ]
  }
}

resource routeTable 'Microsoft.Network/routeTables@2023-09-01' = {
  name: routeTableName
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'default-via-jump'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: jumpPrivateIp
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
          routeTable: {
            id: routeTable.id
          }
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
              locations: [
                location
              ]
            }
          ]
        }
      }
    ]
  }
}

output vnetName string = vnet.name
output vnetId string = vnet.id
output subnetName string = subnetName
output subnetId string = '${vnet.id}/subnets/${subnetName}'
output asgName string = asg.name
