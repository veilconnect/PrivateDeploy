// Cloud Provider Types
export type CloudProvider = 'vultr' | 'digitalocean' | 'linode' | 'aws' | 'hetzner'

// Generic Cloud Configuration
export interface CloudConfig {
  provider: CloudProvider
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
  provider: CloudProvider  // Which cloud provider this instance belongs to
  label: string
  status: string
  region: string
  plan: string
  osId: number
  ipv4: string
  ipv6?: string
  port: number
  password: string
  createdAt: string
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
export interface VultrConfig {
  apiKey: string
  defaultRegion?: string
  defaultPlan?: string
}

export interface VultrRegion extends CloudRegion {}
export interface VultrPlan extends Omit<CloudPlan, 'vcpus'> {
  vcpu_count: number  // Vultr uses this field name
}
export interface VultrNode extends CloudNode {}

// DigitalOcean specific types
export interface DigitalOceanConfig {
  apiKey: string
  defaultRegion?: string
  defaultPlan?: string
}

export interface DigitalOceanRegion extends CloudRegion {}
export interface DigitalOceanPlan extends CloudPlan {}
export interface DigitalOceanDroplet extends CloudNode {}
