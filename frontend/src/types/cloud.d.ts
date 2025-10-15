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
  description: string
  memoryMB: number
  vcpus: number
  diskGB: number
  bandwidthGB: number
}

export interface VultrNode {
  instanceId: string
  label: string
  status: string
  region: string
  plan: string
  osId: number
  ipv4: string
  port: number
  password: string
  createdAt: string
}
