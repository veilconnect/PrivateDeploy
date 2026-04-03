// Cloud Provider Types
export type CloudProvider =
  | 'vultr'
  | 'digitalocean'
  | 'ssh'
  | 'aws'
  // Extra cloud providers are kept disabled until live validation resumes.
  // | 'hetzner'
  // | 'linode'
  // | 'scaleway'
  // | 'upcloud'
  // | 'contabo'
  // | 'oracle'
  | 'manual'

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
  replacedInstanceId?: string
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
  hysteriaServerName?: string
  hysteriaInsecure?: boolean
  vlessPort?: number
  vlessUUID?: string
  vlessPublicKey?: string
  vlessShortId?: string
  vlessServerName?: string
  trojanPort?: number
  trojanPassword?: string
  trojanServerName?: string
  trojanInsecure?: boolean
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

// Region Latency Testing
export interface RegionLatency {
  code: string         // Region code (nrt, fra, lax...)
  name: string         // Region name (Tokyo, Frankfurt...)
  ip: string          // Test IP address
  latency: number     // Average latency in milliseconds
  loss: number        // Packet loss percentage (0-100)
  status: string      // Status: "ok", "timeout", "error"
}

// Connectivity Testing
export interface ConnectivityResult {
  ip: string
  icmpReachable: boolean
  icmpMethod?: string
  baselineReachable?: boolean
  portsOpen: Record<string, boolean>  // merged tcp/udp reachability
  tcpPortsOpen?: Record<string, boolean>
  udpPortsStatus?: Record<string, 'open' | 'closed' | 'open_or_filtered' | 'unknown' | 'error'>
  targetStatus?: Record<string, 'open' | 'closed' | 'open_or_filtered' | 'unknown' | 'error'>
  status: 'reachable' | 'icmp_blocked' | 'blocked' | 'unknown'
}

export type ConnectivityStatus = 'reachable' | 'icmp_blocked' | 'blocked' | 'testing' | 'unknown'

export interface ConnectivityProbeTarget {
  name: string
  port: number
  network: 'tcp' | 'udp'
}

export interface ConnectivityProbeRequest {
  tcpPorts?: number[]
  udpPorts?: number[]
  targets?: ConnectivityProbeTarget[]
  probeICMP?: boolean
  tcpTimeoutMs?: number
  udpTimeoutMs?: number
}

// SSH Provider Types
export interface SSHConfig {
  host: string
  port?: number
  username?: string
  authMethod: 'password' | 'key'
  password?: string
  privateKey?: string
}

export interface SSHServerInfo {
  os: string
  arch: string
  memoryMB: number
}

export interface SSHDeployProgress {
  instanceId: string
  stage: 'connecting' | 'detecting' | 'generating' | 'deploying' | 'verifying' | 'ready' | 'failed'
  message: string
}

// Multi-Deploy Types
export interface MultiDeployResult {
  id: string
  success: boolean
  error?: string
}

export type DeployProgressStatus = 'pending' | 'deploying' | 'ready' | 'failed'
export interface DeployProgress {
  index: number
  status: DeployProgressStatus
  label: string
  message: string
}

// Region Recommendation Types
export interface RegionScore {
  region: CloudRegion
  latencyMs: number
  reachabilityRisk: string
  aiAccess: boolean
  score: number
  reasons: string[]
}

// Health Monitoring Types
export interface HealthResult {
  nodeId: string
  healthy: boolean
  latencyMs: number
  portsOpen: Record<number, boolean>
  lastCheck: string
  consecutiveFailures: number
}
