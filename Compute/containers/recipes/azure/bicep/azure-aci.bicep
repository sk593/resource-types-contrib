@description('NGroups parameter name')
@maxLength(64)
param nGroupsParamName string = 'nGroups_resource_1'

@description('Container Group Profile name')
@maxLength(64)
param containerGroupProfileName string = 'cgp_1'

@description('Load Balancer name')
@maxLength(64)
param loadBalancerName string = 'slb_1'

@description('Backend Address Pool name')
@maxLength(64)
param backendAddressPoolName string = 'bepool_1'

@description('Virtual Network name')
@maxLength(64)
param vnetName string = 'vnet_1'

@description('Subnet name')
@maxLength(64)
param subnetName string = 'subnet_1'

@description('Network Security Group name')
@maxLength(64)
param networkSecurityGroupName string = 'nsg_1'

@description('Inbound Public IP name')
@maxLength(64)
param inboundPublicIPName string = 'inboundPublicIP'

@description('Outbound Public IP name')
@maxLength(64)
param outboundPublicIPName string = 'outboundPublicIP'

@description('NAT Gateway name')
param natGatewayName string = 'natGateway1'

@description('Frontend IP name')
@maxLength(64)
param frontendIPName string = 'loadBalancerFrontend'

@description('HTTP Rule name')
@maxLength(64)
param httpRuleName string = 'httpRule'

@description('Virtual Network address prefix')
@maxLength(64)
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Subnet address prefix')
@maxLength(64)
param subnetAddressPrefix string = '10.0.1.0/24'

@description('Desired container count')
param desiredCount int = 3

@description('Availability zones')
param zones array = []

@description('Maintain desired count')
param maintainDesiredCount bool = true

@description('Inbound NAT Rule name')
@maxLength(64)
param inboundNatRuleName string = 'inboundNatRule'

@description('Radius ACI Container Context')
param context object

// Variables
var cgProfileName = containerGroupProfileName
var nGroupsName = nGroupsParamName
var resourcePrefix = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/'
var loadBalancerApiVersion = '2022-07-01'
var vnetApiVersion = '2022-07-01'
var publicIPVersion = '2022-07-01'
var ddosProtectionPlanName = 'ddosProtectionPlan'

// DDoS Protection Plan
resource ddosProtectionPlan 'Microsoft.Network/ddosProtectionPlans@2022-07-01' = {
  name: ddosProtectionPlanName
  location: resourceGroup().location
}

// Network Security Group
resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2022-07-01' = {
  name: networkSecurityGroupName
  location: resourceGroup().location
  properties: {
    securityRules: [
      {
        name: 'AllowHTTPInbound'
        properties: {
          access: 'Allow'
          description: 'Allow Internet traffic on port range'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '80-331'
          ]
          direction: 'Inbound'
          protocol: '*'
          priority: 100
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
        }
      }
    ]
  }
}

// Inbound Public IP
resource inboundPublicIP 'Microsoft.Network/publicIPAddresses@2022-07-01' = {
  name: inboundPublicIPName
  location: resourceGroup().location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
    ipTags: []
  }
}

// Outbound Public IP
resource outboundPublicIP 'Microsoft.Network/publicIPAddresses@2022-07-01' = {
  name: outboundPublicIPName
  location: resourceGroup().location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
    ipTags: []
  }
}

// NAT Gateway
resource natGateway 'Microsoft.Network/natGateways@2022-07-01' = {
  name: natGatewayName
  location: resourceGroup().location
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: outboundPublicIP.id
      }
    ]
  }
  dependsOn: [
    outboundPublicIP
  ]
}

// Virtual Network
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2022-07-01' = {
  name: vnetName
  location: resourceGroup().location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetAddressPrefix
          serviceEndpoints: []
          delegations: [
            {
              name: 'Microsoft.ContainerInstance.containerGroups'
              id: '${resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)}/delegations/Microsoft.ContainerInstance.containerGroups'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
              type: 'Microsoft.Network/virtualNetworks/subnets/delegations'
            }
          ]
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
          natGateway: {
            id: natGateway.id
          }
        }
        type: 'Microsoft.Network/virtualNetworks/subnets'
      }
    ]
    virtualNetworkPeerings: []
    enableDdosProtection: true
    ddosProtectionPlan: {
      id: ddosProtectionPlan.id
    }
  }
  dependsOn: [
    networkSecurityGroup
    natGateway
  ]
}

// Load Balancer
resource loadBalancer 'Microsoft.Network/loadBalancers@2022-07-01' = {
  name: loadBalancerName
  location: resourceGroup().location
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        properties: {
          publicIPAddress: {
            id: inboundPublicIP.id
          }
          privateIPAllocationMethod: 'Dynamic'
        }
        name: frontendIPName
      }
    ]
    backendAddressPools: [
      {
        name: backendAddressPoolName
        id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, backendAddressPoolName)
        properties: {
          loadBalancerBackendAddresses: []
        }
      }
    ]
    probes: union(
      context.properties.containers.readinessProbe != null ? [
        {
          name: 'readinessProbe'
          properties: {
            protocol: 'Tcp'
            port: context.properties.containers.readinessProbe.tcpSocket.properties.port ?? 80
            intervalInSeconds: context.properties.containers.readinessProbe.periodSeconds ?? 5
            numberOfProbes: context.properties.containers.readinessProbe.failureThreshold ?? 3
            probeThreshold: context.properties.containers.readinessProbe.successThreshold ?? 1
          }
        }
      ] : [],
      context.properties.containers.livenessProbe != null ? [
        {
          name: 'livenessProbe'
          properties: {
            protocol: 'Tcp'
            port: context.properties.containers.livenessProbe.tcpSocket.properties.port ?? 80
            intervalInSeconds: context.properties.containers.livenessProbe.periodSeconds ?? 10
            numberOfProbes: context.properties.containers.livenessProbe.failureThreshold ?? 3
            probeThreshold: context.properties.containers.livenessProbe.successThreshold ?? 1
          }
        }
      ] : []
    )
    loadBalancingRules: [
      {
        name: httpRuleName
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', loadBalancerName, frontendIPName)
          }
          frontendPort: 80
          backendPort: 80
          enableFloatingIP: false
          idleTimeoutInMinutes: 15
          protocol: 'Tcp'
          enableTcpReset: true
          loadDistribution: 'Default'
          disableOutboundSnat: false
          backendAddressPools: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, backendAddressPoolName)
            }
          ]
          probe: context.properties.containers.readinessProbe != null ? {
            id: resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, 'readinessProbe')
          } : null
        }
      }
    ]
    inboundNatRules: [
      {
        name: inboundNatRuleName
        properties: {
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, backendAddressPoolName)
          }
          backendPort: '80'
          enableFloatingIP: 'false'
          enableTcpReset: 'false'
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', loadBalancerName, frontendIPName)
          }
          frontendPortRangeEnd: '331'
          frontendPortRangeStart: '81'
          idleTimeoutInMinutes: '4'
          protocol: 'Tcp'
        }
      }
    ]
    outboundRules: []
    inboundNatPools: []
  }
  dependsOn: [
    inboundPublicIP
    virtualNetwork
  ]
}

// ContainerGroupProfile resource - Create default CGProfile when platformOptions is not provided else use the CGProfile resource provided by the customer.
resource containerGroupProfile 'Microsoft.ContainerInstance/containerGroupProfiles@2024-09-01-preview' = if (context.properties.platformOptions == null) {
  name: cgProfileName
  location: resourceGroup().location
  properties: {
    sku: 'Standard'
    containers: [
      {
        name: 'web'
        properties: {
          image: context.properties.containers.image
          ports: [
            {
              protocol: context.properties.containers.ports != null ? context.properties.containers.ports.additionalProperties.properties.protocol ?? 'TCP' : 'TCP'
              port: context.properties.containers.ports != null ? context.properties.containers.ports.additionalProperties.properties.containerPort : 80
            }
          ]
          resources: {
            requests: {
              memoryInGB: context.properties.containers.resources.?requests.?memoryInMib/1024 ?? json('1.0')
              cpu: context.properties.containers.resources.?requests.?cpu ?? json('1.0')
            }
          }
          volumeMounts: [
            {
              name: 'cacheVolume'
              mountPath: '/mnt/cache' // ephemeral volume path in container filesystem
            }
          ]
        }
      }
    ]
    volumes: [
      {
        name: 'cacheVolume'
        emptyDir: {}   // ephemeral volume
      }
    ]
    restartPolicy: 'Always'
    ipAddress: {
      ports: [
        {
          protocol: 'TCP'
          port: 80
        }
      ]
      type: 'Private'
    }
    osType: 'Linux'
  }
}

// NGroups
resource nGroups 'Microsoft.ContainerInstance/NGroups@2024-09-01-preview' = {
  name: nGroupsName
  location: resourceGroup().location
  zones: zones
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    elasticProfile: {
      desiredCount: desiredCount
      maintainDesiredCount: maintainDesiredCount
    }
    updateProfile: {
      updateMode: 'Rolling'
    }
    containerGroupProfiles: [
      {
        resource: {
          id: '${resourcePrefix}Microsoft.ContainerInstance/containerGroupProfiles/${cgProfileName}'
        }
        containerGroupProperties: {
          subnetIds: [
            {
              id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)
              name: subnetName
            }
          ]
        }
        networkProfile: {
          loadBalancer: {
            backendAddressPools: [
              {
                resource: {
                  id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, backendAddressPoolName)
                }
              }
            ]
          }
        }
      }
    ]
  }
  tags: {
    'reprovision.enabled': true
    'metadata.container.environmentVariable.orchestratorId': true
    'rollingupdate.replace.enabled': true
  }
  dependsOn: [
    containerGroupProfile
    loadBalancer
    virtualNetwork
  ]
}

// Outputs
output result object = {
  secrets: {}
  resources: concat([
    resourceId('Microsoft.Network/ddosProtectionPlans', ddosProtectionPlanName)
    resourceId('Microsoft.Network/networkSecurityGroups', networkSecurityGroupName)
    resourceId('Microsoft.Network/publicIPAddresses', inboundPublicIPName)
    resourceId('Microsoft.Network/publicIPAddresses', outboundPublicIPName)
    resourceId('Microsoft.Network/natGateways', natGatewayName)
    resourceId('Microsoft.Network/virtualNetworks', vnetName)
    resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)
    resourceId('Microsoft.Network/loadBalancers', loadBalancerName)
    resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', loadBalancerName, frontendIPName)
    resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, backendAddressPoolName)
    resourceId('Microsoft.ContainerInstance/NGroups', nGroupsName)
  ], context.properties.platformOptions == null ? [
    resourceId('Microsoft.ContainerInstance/containerGroupProfiles', cgProfileName)
  ] : [], context.properties.containers.readinessProbe != null ? [
    resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, 'readinessProbe')
  ] : [], context.properties.containers.livenessProbe != null ? [
    resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, 'livenessProbe')
  ] : [])
}
