import { ReadFile, WriteFile } from '@/bridge'
import { debounce, ignoredError } from '@/utils'

import {
  NODE_HISTORY_MAX_SAMPLES,
  NODE_HISTORY_RETENTION_MS,
  nodeHistoryPath,
} from './constants'
import { parseJSON } from './helpers'

import type {
  NodeConnectivityHistoryEntry,
  NodeHistoryMap,
  NodeHistoryRecord,
  NodeSpeedHistoryEntry,
} from './types'
import type { ConnectivityResult, ConnectivityStatus } from '@/types/cloud'
import type { Ref, ShallowRef } from 'vue'

type CloudHistoryDeps = {
  nodeHistory: ShallowRef<NodeHistoryMap>
  nodeHistoryLoaded: Ref<boolean>
}

const emptyHistoryRecord = (): NodeHistoryRecord => ({
  connectivity: [],
  speed: [],
})

const normalizeConnectivityEntries = (entries: unknown): NodeConnectivityHistoryEntry[] => {
  if (!Array.isArray(entries)) {
    return []
  }

  return entries
    .map((entry) => {
      const item = entry as Record<string, unknown>
      const timestamp = Number(item.timestamp)
      const status = typeof item.status === 'string' ? item.status as ConnectivityStatus : 'unknown'
      return {
        timestamp: Number.isFinite(timestamp) ? timestamp : 0,
        status,
        targetStatus: item.targetStatus && typeof item.targetStatus === 'object'
          ? Object.fromEntries(Object.entries(item.targetStatus as Record<string, unknown>).map(([key, value]) => [key, String(value)]))
          : undefined,
        portsOpen: item.portsOpen && typeof item.portsOpen === 'object'
          ? Object.fromEntries(Object.entries(item.portsOpen as Record<string, unknown>).map(([key, value]) => [key, Boolean(value)]))
          : undefined,
      }
    })
    .filter((entry) => entry.timestamp > 0)
}

const normalizeSpeedEntries = (entries: unknown): NodeSpeedHistoryEntry[] => {
  if (!Array.isArray(entries)) {
    return []
  }

  return entries
    .map((entry) => {
      const item = entry as Record<string, unknown>
      const timestamp = Number(item.timestamp)
      const speedMbps = item.speedMbps == null ? undefined : Number(item.speedMbps)
      const status: NodeSpeedHistoryEntry['status'] = item.status === 'ok' || item.status === 'partial' || item.status === 'timeout' || item.status === 'error'
        ? item.status
        : 'error'
      const error = typeof item.error === 'string' && item.error.trim().length > 0
        ? item.error.trim()
        : undefined
      return {
        timestamp: Number.isFinite(timestamp) ? timestamp : 0,
        speedMbps: speedMbps != null && Number.isFinite(speedMbps) ? speedMbps : undefined,
        status,
        ...(error ? { error } : {}),
      }
    })
    .filter((entry) => entry.timestamp > 0)
}

export const normalizeNodeHistoryMap = (value: unknown): NodeHistoryMap => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return {}
  }

  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>).map(([instanceId, entry]) => {
      const item = (entry && typeof entry === 'object' && !Array.isArray(entry))
        ? entry as Record<string, unknown>
        : {}
      return [instanceId, {
        connectivity: normalizeConnectivityEntries(item.connectivity),
        speed: normalizeSpeedEntries(item.speed),
      }]
    }),
  )
}

const pruneEntries = <T extends { timestamp: number }>(entries: T[], now: number): T[] => {
  return entries
    .filter((entry) => now - entry.timestamp <= NODE_HISTORY_RETENTION_MS)
    .sort((a, b) => a.timestamp - b.timestamp)
    .slice(-NODE_HISTORY_MAX_SAMPLES)
}

export const pruneNodeHistoryMap = (history: NodeHistoryMap, now: number = Date.now()): NodeHistoryMap => {
  return Object.fromEntries(
    Object.entries(history)
      .map(([instanceId, entry]) => {
        const connectivity = pruneEntries(entry.connectivity || [], now)
        const speed = pruneEntries(entry.speed || [], now)
        if (!connectivity.length && !speed.length) {
          return null
        }
        return [instanceId, { connectivity, speed }]
      })
      .filter((entry): entry is [string, NodeHistoryRecord] => entry !== null),
  )
}

export function createCloudHistory(deps: CloudHistoryDeps) {
  const { nodeHistory, nodeHistoryLoaded } = deps

  const saveNodeHistoryImmediate = async () => {
    const pruned = pruneNodeHistoryMap(nodeHistory.value)
    nodeHistory.value = pruned
    await WriteFile(nodeHistoryPath, JSON.stringify(pruned, null, 2))
  }

  const saveNodeHistory = debounce(saveNodeHistoryImmediate, 500)

  const loadNodeHistory = async () => {
    if (nodeHistoryLoaded.value) {
      return nodeHistory.value
    }

    nodeHistoryLoaded.value = true
    const content = await ignoredError(ReadFile, nodeHistoryPath)
    const parsed = content ? parseJSON<NodeHistoryMap>(content, {}) : {}
    nodeHistory.value = pruneNodeHistoryMap(normalizeNodeHistoryMap(parsed))
    return nodeHistory.value
  }

  const updateNodeHistory = async (
    instanceId: string,
    updater: (record: NodeHistoryRecord) => NodeHistoryRecord,
  ) => {
    await loadNodeHistory()
    const current = nodeHistory.value[instanceId] || emptyHistoryRecord()
    nodeHistory.value = {
      ...nodeHistory.value,
      [instanceId]: updater(current),
    }
    void saveNodeHistory().catch(() => {})
  }

  const clearNodeHistory = async (instanceId?: string) => {
    await loadNodeHistory()
    if (instanceId && instanceId.length > 0) {
      const nextHistory = { ...nodeHistory.value }
      delete nextHistory[instanceId]
      nodeHistory.value = nextHistory
    } else {
      nodeHistory.value = {}
    }
    await saveNodeHistoryImmediate()
  }

  const recordConnectivitySample = async (
    instanceId: string,
    status: ConnectivityStatus,
    result?: ConnectivityResult,
  ) => {
    const sample: NodeConnectivityHistoryEntry = {
      timestamp: Date.now(),
      status,
      ...(result?.targetStatus ? { targetStatus: result.targetStatus } : {}),
      ...(result?.portsOpen ? { portsOpen: result.portsOpen } : {}),
    }

    await updateNodeHistory(instanceId, (record) => ({
      ...record,
      connectivity: [...record.connectivity, sample],
    }))
  }

  const recordSpeedSample = async (
    instanceId: string,
    sample: Omit<NodeSpeedHistoryEntry, 'timestamp'>,
  ) => {
    await updateNodeHistory(instanceId, (record) => ({
      ...record,
      speed: [...record.speed, { timestamp: Date.now(), ...sample }],
    }))
  }

  return {
    loadNodeHistory,
    clearNodeHistory,
    recordConnectivitySample,
    recordSpeedSample,
    saveNodeHistory,
  }
}
