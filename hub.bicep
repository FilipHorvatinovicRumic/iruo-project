targetScope = 'resourceGroup'

param location string = resourceGroup().location
param adminUsername string
param sshPublicKey string
param jumpVmSize string = 'Standard_B2ls_v2'
param leadVmSize string = 'Standard_B2ls_v2'
param tags object = {
  project: 'techsprint'
  environment: 'testing'
}

var vnetName = 'vnet-ts-hub-test'
var subnetName = 'snet-ts-hub-test'
var jumpNsgName = 'nsg-ts-jump-test'
var leadNsgName = 'nsg-ts-lead-test'
var jumpPipName = 'pip-ts-jump-test'
var jumpNicName = 'nic-ts-jump-test'
var leadNicName = 'nic-ts-lead-test'
var jumpVmName = 'vm-ts-jump-test'
var leadVmName = 'vm-ts-lead-test'
var jumpPrivateIp = '10.0.0.4'
var leadPrivateIp = '10.0.0.5'
var rocky = {
  publisher: 'resf'
  offer: 'rockylinux-x86_64'
  sku: '9-base'
  version: 'latest'
}
var rockyPlan = {
  publisher: 'resf'
  product: 'rockylinux-x86_64'
  name: '9-base'
}
var jumpInit = loadTextContent('cloud-init/jump.sh')
var leadInit = replace(loadTextContent('cloud-init/lead.sh'), '__HOSTNAME__', leadVmName)

resource jumpNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: jumpNsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-Internet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource leadNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: leadNsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-From-Jump'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: jumpPrivateIp
          destinationAddressPrefix: '*'
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
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
    ]
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: vnet
  name: subnetName
}

resource jumpPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: jumpPipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource jumpNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: jumpNicName
  location: location
  tags: tags
  properties: {
    enableIPForwarding: true
    networkSecurityGroup: {
      id: jumpNsg.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: jumpPrivateIp
          subnet: {
            id: subnet.id
          }
          publicIPAddress: {
            id: jumpPip.id
          }
        }
      }
    ]
  }
}

resource leadNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: leadNicName
  location: location
  tags: tags
  properties: {
    networkSecurityGroup: {
      id: leadNsg.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: leadPrivateIp
          subnet: {
            id: subnet.id
          }
        }
      }
    ]
  }
}

resource jumpVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: jumpVmName
  location: location
  tags: tags
  plan: rockyPlan
  properties: {
    hardwareProfile: {
      vmSize: jumpVmSize
    }
    storageProfile: {
      imageReference: rocky
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    osProfile: {
      computerName: jumpVmName
      adminUsername: adminUsername
      customData: base64(jumpInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: jumpNic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
  }
}

resource leadVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: leadVmName
  location: location
  tags: tags
  plan: rockyPlan
  properties: {
    hardwareProfile: {
      vmSize: leadVmSize
    }
    storageProfile: {
      imageReference: rocky
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    osProfile: {
      computerName: leadVmName
      adminUsername: adminUsername
      customData: base64(leadInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: leadNic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
  }
}

output vnetName string = vnet.name
output vnetId string = vnet.id
output jumpVmName string = jumpVm.name
output jumpPrivateIp string = jumpPrivateIp
output jumpPublicIp string = jumpPip.properties.ipAddress
output leadVmName string = leadVm.name
output leadPrivateIp string = leadPrivateIp
