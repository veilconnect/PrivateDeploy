/**
 * Cloud Store Types
 *
 * Shared type definitions for the cloud module.
 */

import type { CloudNodeStatus } from './constants'
import type { CloudNode, CloudProvider, ConnectivityResult, ConnectivityStatus } from '@/types/cloud'

export type ManagedCloudNode = CloudNode & {
  statusText?: CloudNodeStatus
  connectivityStatus?: ConnectivityStatus
  connectivityTesting?: boolean
  lastConnectivityResult?: ConnectivityResult
  speedMs?: number
  speedMbps?: number
  speedError?: string
  speedTesting?: boolean
}

export type NodeConnectivityHistoryEntry = {
  timestamp: number
  status: ConnectivityStatus
  targetStatus?: Record<string, string>
  portsOpen?: Record<string, boolean>
}

export type NodeSpeedHistoryEntry = {
  timestamp: number
  speedMbps?: number
  status: 'ok' | 'partial' | 'timeout' | 'error'
  error?: string
}

export type NodeHistoryRecord = {
  connectivity: NodeConnectivityHistoryEntry[]
  speed: NodeSpeedHistoryEntry[]
}

export type NodeHistoryMap = Record<string, NodeHistoryRecord>

export type CloudSubscriptionEntry = IProxy & {
  instanceId: string
  managedExclude: string
}

export type ManualNodeInput = {
  instanceId?: string
  label: string
  ipv4?: string
  ipv6?: string
  region?: string
  plan?: string
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
  createdAt?: string
}

export type ManualNodeConflictType = 'label' | 'ipv4' | 'ipv6'

export type ManualNodeConflict = {
  type: ManualNodeConflictType
  value: string
  existing: ManagedCloudNode
}

export type ManualNodeSkipEntry = {
  identifier: string
  reason: ManualNodeConflictType
  existingLabel?: string
  existingProvider?: CloudProvider
}

export class ManualNodeError extends Error {
  code: string
  meta?: Record<string, any>

  constructor(code: string, meta?: Record<string, any>) {
    super(code)
    this.code = code
    this.meta = meta
    this.name = 'ManualNodeError'
  }
}
