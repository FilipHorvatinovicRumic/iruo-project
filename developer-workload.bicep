targetScope = 'resourceGroup'

param location string = resourceGroup().location
param developerSlug string
param developerDisplayName string
param vnetName string
param subnetName string
param asgName string
param loadBalancerIp string
param adminUsername string
param sshPublicKey string
param appVmSize string = 'Standard_B2ls_v2'
param blobStorageName string
param fileStorageName string
param tags object = {
  project: 'techsprint'
  environment: 'testing'
}

var lbName = 'lb-ts-${developerSlug}-int'
var vm1Name = 'vm-ts-${developerSlug}-app01'
var vm2Name = 'vm-ts-${developerSlug}-app02'
var nic1Name = 'nic-ts-${developerSlug}-app01'
var nic2Name = 'nic-ts-${developerSlug}-app02'
var backendPoolName = 'be-app'
var frontendName = 'fe-app'
var probeName = 'probe-http'
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
var initTemplate = loadTextContent('cloud-init/app.sh')
var initCommon1 = replace(initTemplate, '__DEV_SLUG__', developerSlug)
var initCommon2 = replace(initCommon1, '__DEV_DISPLAY__', developerDisplayName)
var initCommon3 = replace(initCommon2, '__LB_IP__', loadBalancerIp)
var initCommon4 = replace(initCommon3, '__BLOB_ACCOUNT__', blobStorageName)
var initCommon5 = replace(initCommon4, '__FILE_ACCOUNT__', fileStorageName)
var initVm1 = replace(initCommon5, '__HOSTNAME__', vm1Name)
var initVm2 = replace(initCommon5, '__HOSTNAME__', vm2Name)

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: vnet
  name: subnetName
}

resource asg 'Microsoft.Network/applicationSecurityGroups@2023-09-01' existing = {
  name: asgName
}

resource blobStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: blobStorageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          action: 'Allow'
          id: subnet.id
        }
      ]
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: blobStorage
  name: 'default'
  properties: {}
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'moodle-files'
  properties: {
    publicAccess: 'None'
  }
}

resource fileStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: fileStorageName
  location: location
  tags: tags
  sku: {
    name: 'Premium_LRS'
  }
  kind: 'FileStorage'
  properties: {
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: false
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          action: 'Allow'
          id: subnet.id
        }
      ]
    }
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: fileStorage
  name: 'default'
  properties: {}
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: 'moodle-backups'
  properties: {
    accessTier: 'Premium'
    enabledProtocols: 'NFS'
    rootSquash: 'NoRootSquash'
    shareQuota: 100
  }
}

resource lb 'Microsoft.Network/loadBalancers@2023-09-01' = {
  name: lbName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: frontendName
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: loadBalancerIp
          subnet: {
            id: subnet.id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: backendPoolName
      }
    ]
    probes: [
      {
        name: probeName
        properties: {
          protocol: 'Tcp'
          port: 80
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'rule-http'
        properties: {
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
          loadDistribution: 'Default'
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, frontendName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, backendPoolName)
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, probeName)
          }
        }
      }
    ]
  }
}

resource nic1 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: nic1Name
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnet.id
          }
          loadBalancerBackendAddressPools: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, backendPoolName)
            }
          ]
          applicationSecurityGroups: [
            {
              id: asg.id
            }
          ]
        }
      }
    ]
  }
  dependsOn: [
    lb
  ]
}

resource nic2 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: nic2Name
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnet.id
          }
          loadBalancerBackendAddressPools: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, backendPoolName)
            }
          ]
          applicationSecurityGroups: [
            {
              id: asg.id
            }
          ]
        }
      }
    ]
  }
  dependsOn: [
    lb
  ]
}

resource vm1 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vm1Name
  location: location
  tags: tags
  plan: rockyPlan
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: appVmSize
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
      dataDisks: [
        {
          lun: 0
          name: 'disk-${vm1Name}-data'
          createOption: 'Empty'
          deleteOption: 'Delete'
          diskSizeGB: 32
          managedDisk: {
            storageAccountType: 'StandardSSD_LRS'
          }
        }
      ]
    }
    osProfile: {
      computerName: vm1Name
      adminUsername: adminUsername
      customData: base64(initVm1)
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
          id: nic1.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
  }
}

resource vm2 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vm2Name
  location: location
  tags: tags
  plan: rockyPlan
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: appVmSize
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
      dataDisks: [
        {
          lun: 0
          name: 'disk-${vm2Name}-data'
          createOption: 'Empty'
          deleteOption: 'Delete'
          diskSizeGB: 32
          managedDisk: {
            storageAccountType: 'StandardSSD_LRS'
          }
        }
      ]
    }
    osProfile: {
      computerName: vm2Name
      adminUsername: adminUsername
      customData: base64(initVm2)
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
          id: nic2.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
  }
}

output loadBalancerIp string = loadBalancerIp
output vm1Name string = vm1.name
output vm2Name string = vm2.name
output vm1PrincipalId string = vm1.identity.principalId
output vm2PrincipalId string = vm2.identity.principalId
output blobStorageId string = blobStorage.id
output blobStorageName string = blobStorage.name
output fileStorageName string = fileStorage.name
