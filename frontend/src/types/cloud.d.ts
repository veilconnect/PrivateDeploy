export interface VultrConfig {
  apiKey: string
  defaultRegion?: string
  defaultPlan?: string
}

export interface VultrRegion {
  id: string
  city: string
  country: string
  continent: string
}

export interface VultrPlan {
  id: string
  description?: string
  ram: number              // Memory in MB (API field name)
  vcpu_count: number      // Number of vCPUs (API field name)
  disk: number            // Disk size in GB (API field name)
  bandwidth: number       // Bandwidth in GB (API field name)
  monthly_cost?: number   // Monthly cost in USD (API field name)
  hourly_cost?: number    // Hourly cost in USD (API field name)
  type?: string
  locations?: string[]
}

export interface VultrNode {
  instanceId: string
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
