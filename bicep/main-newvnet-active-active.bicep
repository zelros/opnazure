// Parameters
@sys.description('VM size, please choose a size which allow 2 NICs.')
param virtualMachineSize string = 'Standard_B2s'

@sys.description('OPN NVA Manchine Name')
param virtualMachineName string

@sys.description('Default Temporary Admin username (Used for JumpBox and temporarily deploy FreeBSD VM).')
param TempUsername string

@sys.description('Default Temporary Admin password (Used for JumpBox and temporarily deploy FreeBSD VM).')
@secure()
param TempPassword string

@sys.description('Virtual Nework Name')
param virtualNetworkName string = 'OPN-VNET'

@sys.description('Virtual Address Space')
param VNETAddress array = [
  '10.0.0.0/16'
]

@sys.description('Untrusted-Subnet Address Space')
param UntrustedSubnetCIDR string = '10.0.0.0/24'

@sys.description('Trusted-Subnet Address Space')
param TrustedSubnetCIDR string = '10.0.1.0/24'

@sys.description('Specify Public IP SKU either Basic (lowest cost) or Standard (Required for HA LB)"')
@allowed([
  'Basic'
  'Standard'
])
param PublicIPAddressSku string = 'Standard'

@sys.description('URI for Custom OPN Script and Config')
param OpnScriptURI string = 'https://raw.githubusercontent.com/dmauser/opnazure/master/scripts/'

@sys.description('Shell Script to be executed')
param ShellScriptName string = 'configureopnsense.sh'

@sys.description('Deploy Windows VM Trusted Subnet')
param DeployWindows bool = false

// Variables
var untrustedSubnetName = 'Untrusted-Subnet'
var trustedSubnetName = 'Trusted-Subnet'
var VMOPNsensePrimaryName = '${virtualMachineName}-Primary'
var VMOPNsenseSecondaryName = '${virtualMachineName}-Secondary'
var publicIPAddressName = '${virtualMachineName}-PublicIP'
var networkSecurityGroupName = '${virtualMachineName}-NSG'
var externalLoadBalanceName = 'External-LoadBalance'
var externalLoadBalanceFIPConfName = 'FW'
var externalLoadBalanceBAPName = 'OPNSense'
var externalLoadBalanceProbeName = 'HTTPs'
var externalLoadBalancingRuleName = 'WEB'
var externalLoadBalanceOutRuleName = 'OutBound-OPNSense'
var internalLoadBalanceName = 'Internal-LoadBalance'
var internalLoadBalanceFIPConfName = 'FW'
var internalLoadBalanceBAPName = 'OPNSense'
var internalLoadBalanceProbeName = 'HTTPs'
var internalLoadBalancingRuleName = 'Internal-HA-Port-Rule'

var winvmName = 'VM-Win11Client'
var winvmnetworkSecurityGroupName = '${winvmName}-NSG'
var winvmpublicipName = '${winvmName}-PublicIP'

// Resources
// Create NSG
module nsgopnsense 'modules/vnet/nsg.bicep' = {
  name: networkSecurityGroupName
  params: {
    nsgName: networkSecurityGroupName
    securityRules: [
      {
        name: 'In-Any'
        properties: {
          priority: 4096
          sourceAddressPrefix: '*'
          protocol: '*'
          destinationPortRange: '*'
          access: 'Allow'
          direction: 'Inbound'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Out-Any'
        properties: {
          priority: 4096
          sourceAddressPrefix: '*'
          protocol: '*'
          destinationPortRange: '*'
          access: 'Allow'
          direction: 'Outbound'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// Create VNET
module vnet 'modules/vnet/vnet.bicep' = {
  name: virtualNetworkName
  params: {
    vnetAddressSpace: VNETAddress
    vnetName: virtualNetworkName
    subnets: [
      {
        name: untrustedSubnetName
        properties: {
          addressPrefix: UntrustedSubnetCIDR
        }
      }
      {
        name: trustedSubnetName
        properties: {
          addressPrefix: TrustedSubnetCIDR
        }
      }
    ]
  }
}

// Create OPNsense Public IP
module publicip 'modules/vnet/publicip.bicep' = {
  name: publicIPAddressName
  params: {
    publicipName: publicIPAddressName
    publicipproperties: {
      publicIPAllocationMethod: 'Static'
    }
    publicipsku: {
      name: PublicIPAddressSku
      tier: 'Regional'
    }
  }
}

// Build reference of existing subnets
resource untrustedSubnet 'Microsoft.Network/virtualNetworks/subnets@2020-11-01' existing = {
  name: '${virtualNetworkName}/${untrustedSubnetName}'
}

resource trustedSubnet 'Microsoft.Network/virtualNetworks/subnets@2020-11-01' existing = {
  name: '${virtualNetworkName}/${trustedSubnetName}'
}

// External Load Balancer
module elb 'modules/vnet/lb.bicep' = {
  name: externalLoadBalanceName
  params: {
    lbName: externalLoadBalanceName
    frontendIPConfigurations: [
      {
        name: externalLoadBalanceFIPConfName
        properties: {
          publicIPAddress: {
            id: publicip.outputs.publicipId
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: externalLoadBalanceBAPName
      }
    ]
    loadBalancingRules: [
      {
        name: externalLoadBalancingRuleName
        properties: {
          frontendPort: 443
          backendPort: 443
          protocol: 'Tcp'
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', externalLoadBalanceName, externalLoadBalanceFIPConfName)
          }
          disableOutboundSnat: true
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', externalLoadBalanceName, externalLoadBalanceBAPName)
          }
          backendAddressPools: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', externalLoadBalanceName, externalLoadBalanceBAPName)
            }
          ]
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', externalLoadBalanceName, externalLoadBalanceProbeName)
          }
        }
      }
    ]
    probe: [
      {
        name: externalLoadBalanceProbeName
        properties: {
          port: 443
          protocol: 'Tcp'
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    outboundRules: [
      {
        name: externalLoadBalanceOutRuleName
        properties: {
          allocatedOutboundPorts: 0
          idleTimeoutInMinutes: 4
          enableTcpReset: true
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', externalLoadBalanceName, externalLoadBalanceBAPName)
          }
          frontendIPConfigurations: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', externalLoadBalanceName, externalLoadBalanceFIPConfName)
            }
          ]
          protocol: 'All'
        }
      }
    ]
  }
}

// Internal Load Balancer
module ilb 'modules/vnet/lb.bicep' = {
  name: internalLoadBalanceName
  params: {
    lbName: internalLoadBalanceName
    frontendIPConfigurations: [
      {
        name: internalLoadBalanceFIPConfName
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: trustedSubnet.id
          }
          privateIPAddressVersion: 'IPv4'
        }
      }
    ]
    backendAddressPools: [
      {
        name: internalLoadBalanceBAPName
      }
    ]

    loadBalancingRules: [
      {
        name: internalLoadBalancingRuleName
        properties: {
          frontendPort: 0
          backendPort: 0
          protocol: 'All'
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', internalLoadBalanceName, internalLoadBalanceFIPConfName)
          }
          disableOutboundSnat: true
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', internalLoadBalanceName, internalLoadBalanceBAPName)
          }
          backendAddressPools: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', internalLoadBalanceName, internalLoadBalanceBAPName)
            }
          ]
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', internalLoadBalanceName, internalLoadBalanceProbeName)
          }
        }
      }
    ]
    probe: [
      {
        name: internalLoadBalanceProbeName
        properties: {
          port: 443
          protocol: 'Tcp'
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
  }
  dependsOn: [
    vnet
  ]
}

// Create OPNsense
module opnSenseSecondary 'modules/VM/opnsense-vm-active-active.bicep' = {
  name: VMOPNsenseSecondaryName
  params: {
    ShellScriptParameters: '${OpnScriptURI} Secondary ${TrustedSubnetCIDR}'
    OPNScriptURI: OpnScriptURI
    ShellScriptName: ShellScriptName
    TempPassword: TempPassword
    TempUsername: TempUsername
    trustedSubnetId: trustedSubnet.id
    untrustedSubnetId: untrustedSubnet.id
    virtualMachineName: VMOPNsenseSecondaryName
    virtualMachineSize: virtualMachineSize
    nsgId: nsgopnsense.outputs.nsgID
    ExternalLoadBalancerBackendAddressPoolId: elb.outputs.backendAddressPools[0].id
    InternalLoadBalancerBackendAddressPoolId: ilb.outputs.backendAddressPools[0].id
  }
  dependsOn: [
    vnet
    nsgopnsense
  ]
}

module opnSensePrimary 'modules/VM/opnsense-vm-active-active.bicep' = {
  name: VMOPNsensePrimaryName
  params: {
    ShellScriptParameters: '${OpnScriptURI} Primary ${TrustedSubnetCIDR} ${opnSenseSecondary.outputs.trustedNicIP}'
    OPNScriptURI: OpnScriptURI
    ShellScriptName: ShellScriptName
    TempPassword: TempPassword
    TempUsername: TempUsername
    trustedSubnetId: trustedSubnet.id
    untrustedSubnetId: untrustedSubnet.id
    virtualMachineName: VMOPNsensePrimaryName
    virtualMachineSize: virtualMachineSize
    nsgId: nsgopnsense.outputs.nsgID
    ExternalLoadBalancerBackendAddressPoolId: elb.outputs.backendAddressPools[0].id
    InternalLoadBalancerBackendAddressPoolId: ilb.outputs.backendAddressPools[0].id
  }
  dependsOn: [
    vnet
    nsgopnsense
    opnSenseSecondary
  ]
}

// Windows11 Client Resources
module nsgwinvm 'modules/vnet/nsg.bicep' = if (DeployWindows) {
  name: winvmnetworkSecurityGroupName
  params: {
    nsgName: winvmnetworkSecurityGroupName
    securityRules: [
      {
        name: 'RDP'
        properties: {
          priority: 4096
          sourceAddressPrefix: '*'
          protocol: 'Tcp'
          destinationPortRange: '3389'
          access: 'Allow'
          direction: 'Inbound'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Out-Any'
        properties: {
          priority: 4096
          sourceAddressPrefix: '*'
          protocol: '*'
          destinationPortRange: '*'
          access: 'Allow'
          direction: 'Outbound'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
  dependsOn: [
    opnSenseSecondary
    opnSensePrimary
  ]
}

module winvmpublicip 'modules/vnet/publicip.bicep' = if (DeployWindows) {
  name: winvmpublicipName
  params: {
    publicipName: winvmpublicipName
    publicipproperties: {
      publicIPAllocationMethod: 'Static'
    }
    publicipsku: {
      name: PublicIPAddressSku
      tier: 'Regional'
    }
  }
  dependsOn: [
    opnSenseSecondary
    opnSensePrimary
  ]
}

resource nsgwinvmexist 'Microsoft.Network/networkSecurityGroups@2021-03-01' existing = {
  name: winvmnetworkSecurityGroupName
}

resource winvmpublicipexist 'Microsoft.Network/publicIPAddresses@2021-03-01' existing = {
  name: winvmpublicipName
}
module winvm 'modules/VM/windows11-vm.bicep' = if (DeployWindows) {
  name: winvmName
  params: {
    nsgId: nsgwinvmexist.id
    publicIPId: winvmpublicipexist.id
    TempPassword: TempPassword
    TempUsername: TempUsername
    trustedSubnetId: trustedSubnet.id
    virtualMachineName: winvmName
    virtualMachineSize: 'Standard_B4ms'
  }
  dependsOn: [
    opnSenseSecondary
    opnSensePrimary
    nsgwinvm
    winvmpublicip
  ]
}
