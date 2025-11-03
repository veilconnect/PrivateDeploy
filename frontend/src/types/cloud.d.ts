// Cloud Provider Types
export type CloudProvider = 'vultr' | 'digitalocean' | 'linode' | 'aws' | 'hetzner'

// Generic Cloud Configuration
export interface CloudConfig {
  provider?: CloudProvider
  apiKey: string
  defaultRegion?: string
  defaultPlan?: string
  extra?: Record<string, string>
}

// Generic Cloud Region
export interface CloudRegion {
  id: string
  city: string
  country: string
  continent?: string
}

// Generic Cloud Plan
export interface CloudPlan {
  id: string
  description?: string
  ram: number              // Memory in MB
  vcpus: number            // Number of vCPUs
  disk: number             // Disk size in GB
  bandwidth: number        // Bandwidth in GB
  monthlyCost?: number     // Monthly cost in USD
  hourlyCost?: number      // Hourly cost in USD
  type?: string
  locations?: string[]
}

// Generic Cloud Node/Instance
export interface CloudNode {
  instanceId: string
  provider?: CloudProvider  // Which cloud provider this instance belongs to
  label: string
  status?: string
  region?: string
  plan?: string
  osId?: number
  ipv4?: string
  ipv6?: string
  port?: number
  password?: string
  createdAt?: string
  // Multi-protocol configuration
  ssPort?: number
  ssPassword?: string
  hysteriaPort?: number
  hysteriaPassword?: string
  vlessPort?: number
  vlessUUID?: string
  vlessPublicKey?: string
  vlessShortId?: string
  trojanPort?: number
  trojanPassword?: string
}

// Legacy types for backward compatibility
export type VultrConfig = CloudConfig
export type VultrRegion = CloudRegion
export type VultrPlan = CloudPlan
export type VultrNode = CloudNode

export type DigitalOceanConfig = CloudConfig
export type DigitalOceanRegion = CloudRegion
export type DigitalOceanPlan = CloudPlan
export type DigitalOceanDroplet = CloudNode
