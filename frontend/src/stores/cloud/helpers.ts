/**
 * Cloud Store Helper Functions
 *
 * Pure utility functions used across the cloud module.
 * No dependencies on Vue reactivity or store state.
 */

import { logError } from '@/utils/logger'

import type { CloudProvider, CloudNode } from '@/types/cloud'
import type { ManagedProtocol, ProtocolHealthEntry, ProtocolExcludePattern, CloudNodeStatus } from './constants'
import {
  CloudSubscriptionPrefix,
  CloudSmartOutboundIds,
  CloudSmartLegacyIds,
  CloudSmartNodeOutboundPrefix,
  ProtocolExcludePattern as ExcludePatterns,
} from './constants'

import type { ManagedCloudNode } from './types'

// ─── JSON Parsing ────────────────────────────────────────────────────────────

export const parseJSON = <T>(data: string | undefined | null, fallback: T): T => {
  if (!data) return fallback
  try {
    return JSON.parse(data) as T
  } catch (error) {
    logError('Failed to parse provider response', error)
    return fallback
  }
}

// ─── Subscription ID Management ──────────────────────────────────────────────

export const subscriptionId = (instanceId: string) => {
  if (instanceId.startsWith('cloud-')) {
    return instanceId
  }
  return `cloud-${instanceId}`
}

export const subscriptionPath = (instanceId: string) =>
  `data/subscribes/${subscriptionId(instanceId)}.json`

export const cloudInstanceIdFromSubscriptionRef = (id: string) => {
  if (id.startsWith('cloud-do-')) {
    return id
  }
  if (id.startsWith(CloudSubscriptionPrefix)) {
    return id.slice(CloudSubscriptionPrefix.length)
  }
  return id
}

export const nodeSmartOutboundId = (instanceId: string) =>
  `${CloudSmartNodeOutboundPrefix}auto-${subscriptionId(instanceId)}`

// ─── Outbound ID Detection ──────────────────────────────────────────────────

export const isManagedCloudOutboundId = (id?: string) => {
  const normalized = String(id || '')
  return (
    Object.values(CloudSmartOutboundIds).includes(
      normalized as (typeof CloudSmartOutboundIds)[keyof typeof CloudSmartOutboundIds],
    ) ||
    CloudSmartLegacyIds.Outbounds.includes(normalized as any) ||
    normalized.startsWith(CloudSmartNodeOutboundPrefix)
  )
}

// ─── Protocol Health Helpers ─────────────────────────────────────────────────

export const joinRegexAlternatives = (...patterns: Array<string | undefined>) => {
  return patterns
    .map((pattern) => pattern?.trim())
    .filter((pattern): pattern is string => !!pattern)
    .map((pattern) => `(?:${pattern})`)
    .join('|')
}

export const deriveManagedExclude = (
  entry?: Partial<Record<ManagedProtocol, ProtocolHealthEntry>>,
) => {
  if (!entry) return ''
  return joinRegexAlternatives(
    ...Object.entries(entry)
      .filter(([, value]) => value?.state === 'degraded')
      .map(([protocol]) => ExcludePatterns[protocol as ManagedProtocol]),
  )
}

// ─── TLS & Server Name Helpers ───────────────────────────────────────────────

export const normalizeServerName = (value: unknown, fallback: string) => {
  if (typeof value !== 'string') return fallback
  const trimmed = value.trim()
  return trimmed || fallback
}

export const resolveTLSInsecure = (node: CloudNode, protocol: 'hysteria' | 'trojan') => {
  const insecureFlag =
    protocol === 'hysteria' ? node.hysteriaInsecure : node.trojanInsecure
  if (typeof insecureFlag === 'boolean') {
    return insecureFlag
  }
  return false
}

export const isReachableTargetStatus = (status?: string) =>
  status === 'open' || status === 'open_or_filtered'

// ─── Port Helpers ────────────────────────────────────────────────────────────

export const addUniquePort = (target: number[], port?: number) => {
  if (!port || port <= 0) return
  if (!target.includes(port)) {
    target.push(port)
  }
}

// ─── IP Address Helpers ──────────────────────────────────────────────────────

export const isPublicIPv4Address = (ip?: string) => {
  if (!ip) return false
  const octets = ip.split('.')
  if (octets.length !== 4) return false

  const first = parseInt(octets[0], 10)
  const second = parseInt(octets[1], 10)

  // CGNAT range: 100.64.0.0/10
  if (first === 100 && second >= 64 && second <= 127) return false
  // Private ranges
  if (first === 10) return false
  if (first === 192 && second === 168) return false
  if (first === 172 && second >= 16 && second <= 31) return false
  if (ip === '0.0.0.0') return false

  return true
}

export const hasUsableAddress = (node: ManagedCloudNode) =>
  (isPublicIPv4Address(node.ipv4) || (!!node.ipv6 && node.ipv6 !== '::')) && !!node.instanceId

// ─── Node Normalization ──────────────────────────────────────────────────────

export const normalizeCloudNode = (
  rawNode: Record<string, any>,
  providerFallback: CloudProvider,
): ManagedCloudNode => {
  const node = { ...rawNode } as Record<string, any>

  node.instanceId = node.instanceId || node.InstanceID || node.id || node.ID || ''
  node.label = node.label || node.name || node.Label || node.instanceId
  node.provider = node.provider || providerFallback

  if (node.createdAt && typeof node.createdAt !== 'string') {
    const date = new Date(node.createdAt)
    node.createdAt = Number.isNaN(date.getTime()) ? String(node.createdAt) : date.toISOString()
  }

  return node as ManagedCloudNode
}

export const providerStatusToNodeStatus = (status?: string): CloudNodeStatus => {
  if (!status) return 'unknown'
  const normalized = status.toLowerCase()
  if (['active', 'running', 'ok', 'online', 'started'].includes(normalized)) {
    return 'connected'
  }
  if (['pending', 'installing', 'starting', 'booting', 'provisioning'].includes(normalized)) {
    return 'pending'
  }
  if (['applying', 'deploying', 'configuring'].includes(normalized)) {
    return 'applying'
  }
  if (['failed', 'error', 'stopped', 'poweroff', 'locked', 'blocked'].includes(normalized)) {
    return 'error'
  }
  return 'unknown'
}
