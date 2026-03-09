/**
 * Cloud Store Constants
 *
 * Centralized constants for protocol patterns, smart routing IDs,
 * and configuration defaults used across the cloud module.
 */

import { DefaultTestURL } from '@/constant/app'

// ─── Protocol Types ──────────────────────────────────────────────────────────

export type ManagedProtocol = 'shadowsocks' | 'hysteria2' | 'vless' | 'trojan'
export type ProtocolHealthState = 'healthy' | 'degraded'
export type ProtocolHealthReason =
  | 'connectivity-udp-unreachable'
  | 'connectivity-tcp-unreachable'
  | 'manual-override'

export type ProtocolHealthEntry = {
  state: ProtocolHealthState
  reason: ProtocolHealthReason
  updatedAt: number
}

export type ProtocolHealthMap = Record<string, Partial<Record<ManagedProtocol, ProtocolHealthEntry>>>

// ─── Cloud Node Types ────────────────────────────────────────────────────────

export type CloudNodeStatus = 'unknown' | 'pending' | 'applying' | 'connected' | 'error'

// ─── Subscription & Routing IDs ──────────────────────────────────────────────

export const CloudSubscriptionPrefix = 'cloud-'
export const CloudSmartNodeOutboundPrefix = 'outbound-smart-node-'

export const CloudSmartOutboundIds = {
  Auto: 'outbound-smart-auto',
  TcpPrimary: 'outbound-smart-tcp-primary',
  TcpSecondary: 'outbound-smart-tcp-secondary',
  UdpAuto: 'outbound-smart-udp-auto',
  HysteriaAuto: 'outbound-smart-hysteria-auto',
} as const

export const CloudSmartRuleIds = {
  Tcp443Route: 'rule-smart-tcp-443-route',
  TcpWebRoute: 'rule-smart-tcp-web-route',
  UdpRoute: 'rule-smart-udp-route',
} as const

export const CloudSmartLegacyIds = {
  Outbounds: [
    'cloud-smart-tcp-auto',
    'cloud-smart-udp-auto',
    'cloud-smart-hysteria-auto',
    'outbound-smart-tcp-primary',
    'outbound-smart-tcp-secondary',
  ],
  Rules: ['cloud-smart-udp-route', 'rule-smart-tcp-443-route', 'rule-smart-tcp-web-route'],
} as const

// ─── Protocol Tag Patterns (regex) ──────────────────────────────────────────

const CloudTagSuffixPattern = '(?:-(?:v4|v6|ipv4|ipv6))?$'

export const ProtocolTagPattern: Record<ManagedProtocol, string> = {
  shadowsocks: `-(?:ss|shadowsocks)${CloudTagSuffixPattern}`,
  hysteria2: `-(?:hysteria2?|hy2)${CloudTagSuffixPattern}`,
  vless: `-(?:vless)${CloudTagSuffixPattern}`,
  trojan: `-(?:trojan)${CloudTagSuffixPattern}`,
}

export const SmartProtocolInclude = {
  NodeBest: `-(?:ss|shadowsocks|hysteria2?|hy2|vless|trojan)${CloudTagSuffixPattern}`,
  Udp: ProtocolTagPattern.shadowsocks,
  Hysteria: ProtocolTagPattern.hysteria2,
} as const

export const ProtocolExcludePattern: Record<ManagedProtocol, string> = {
  shadowsocks: ProtocolTagPattern.shadowsocks,
  hysteria2: ProtocolTagPattern.hysteria2,
  vless: ProtocolTagPattern.vless,
  trojan: ProtocolTagPattern.trojan,
}

// ─── Default Server Names ────────────────────────────────────────────────────

export const DefaultHysteriaServerName = 'www.bing.com'
export const DefaultVlessServerName = 'www.microsoft.com'
export const DefaultTrojanServerName = 'www.microsoft.com'

// ─── Smart Routing Probe URLs ────────────────────────────────────────────────

export const CloudSmartProbeURLPrimary = DefaultTestURL
export const CloudSmartProbeURLSecondary = 'https://www.cloudflare.com/cdn-cgi/trace'

// ─── File Paths ──────────────────────────────────────────────────────────────

export const manualNodesPath = 'data/cloud/manual-nodes.json'
export const protocolHealthPath = 'data/cloud/protocol-health.json'

// ─── Cache TTL ───────────────────────────────────────────────────────────────

export const CACHE_TTL = {
  regions: 30 * 60 * 1000,            // 30 minutes
  plans: 30 * 60 * 1000,              // 30 minutes
  instances: 2 * 60 * 1000,           // 2 minutes
  instancesBackground: 5 * 60 * 1000, // 5 minutes
  latency: 24 * 60 * 60 * 1000,       // 24 hours
} as const
