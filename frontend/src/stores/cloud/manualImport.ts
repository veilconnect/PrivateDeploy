/**
 * Cloud Store - Manual Node Import
 *
 * Handles manual node management: loading, saving, adding, updating,
 * removing manual nodes, and syncing them into the instances list.
 */

import type { Ref, ShallowRef } from 'vue'

import { ReadFile, WriteFile } from '@/bridge'
import { ignoredError, sampleID, debounce } from '@/utils'
import { logError, logInfo } from '@/utils/logger'

import { manualNodesPath } from './constants'
import type { CloudNodeStatus } from './constants'
import type { CloudProvider } from '@/types/cloud'

import { parseJSON } from './helpers'
import {
  ManualNodeError,
  type ManagedCloudNode,
  type ManualNodeInput,
  type ManualNodeConflict,
  type ManualNodeConflictType,
  type ManualNodeSkipEntry,
} from './types'

export type ManualImportDeps = {
  manualNodes: ShallowRef<ManagedCloudNode[]>
  manualNodesLoaded: Ref<boolean>
  instances: ShallowRef<ManagedCloudNode[]>
  instancesUpdatedAt: Ref<number | null>
  markNodeStatus: (instanceId: string, status: CloudNodeStatus) => void
  ensureSubscriptionForNode: (node: ManagedCloudNode) => Promise<void>
}

const sanitizePort = (value: unknown): number | undefined => {
  const num = Number(value)
  if (!Number.isFinite(num)) return undefined
  const port = Math.trunc(num)
  if (port <= 0 || port > 65535) return undefined
  return port
}

export function createManualImport(deps: ManualImportDeps) {
  const {
    manualNodes,
    manualNodesLoaded,
    instances,
    instancesUpdatedAt,
    markNodeStatus,
    ensureSubscriptionForNode,
  } = deps

  const syncManualNodesIntoInstances = () => {
    if (!manualNodes.value.length) {
      if (instances.value.some((node) => node.provider === 'manual')) {
        instances.value = instances.value.filter((node) => node.provider !== 'manual')
        instancesUpdatedAt.value = Date.now()
      }
      return
    }
    const others = instances.value.filter((node) => node.provider !== 'manual')
    const normalizedManual = manualNodes.value.map((node) => ({
      ...node,
      provider: (node.provider as CloudProvider) || 'manual',
      statusText: node.statusText || 'connected',
    }))
    instances.value = [...others, ...normalizedManual]
    instancesUpdatedAt.value = Date.now()
  }

  const loadManualNodes = async () => {
    if (!manualNodesLoaded.value) {
      manualNodesLoaded.value = true
      const content = await ignoredError(ReadFile, manualNodesPath)
      if (content) {
        const parsed = parseJSON<ManagedCloudNode[]>(content, [])
        manualNodes.value = parsed.map((node) => ({
          ...node,
          provider: (node.provider as CloudProvider) || 'manual',
          status: node.status || 'active',
          statusText: node.statusText || 'connected',
          createdAt: typeof node.createdAt === 'string' && node.createdAt ? node.createdAt : new Date().toISOString(),
        }))
      } else {
        manualNodes.value = []
      }
    }
    syncManualNodesIntoInstances()
    return manualNodes.value
  }

  const saveManualNodesImmediate = async () => {
    await WriteFile(manualNodesPath, JSON.stringify(manualNodes.value, null, 2))
  }
  const saveManualNodes = debounce(saveManualNodesImmediate, 1000)

  const findManualConflict = (input: ManualNodeInput, currentId?: string): ManualNodeConflict | null => {
    const normalizedLabel = input.label.trim()
    const normalizedIpv4 = input.ipv4?.trim()
    const normalizedIpv6 = input.ipv6?.trim()

    const conflictWith = (node: ManagedCloudNode): ManualNodeConflict | null => {
      if (node.instanceId === currentId) return null
      if (normalizedLabel && node.label === normalizedLabel) {
        return { type: 'label', value: normalizedLabel, existing: node }
      }
      if (normalizedIpv4 && node.ipv4 && node.ipv4 === normalizedIpv4) {
        return { type: 'ipv4', value: normalizedIpv4, existing: node }
      }
      if (normalizedIpv6 && node.ipv6 && node.ipv6 === normalizedIpv6) {
        return { type: 'ipv6', value: normalizedIpv6, existing: node }
      }
      return null
    }

    for (const node of manualNodes.value) {
      const conflict = conflictWith(node)
      if (conflict) return conflict
    }

    for (const node of instances.value) {
      if (node.provider === 'manual') continue
      const conflict = conflictWith(node)
      if (conflict) return conflict
    }

    return null
  }

  const createManualNode = (input: ManualNodeInput, currentId?: string): ManagedCloudNode => {
    const label = input.label.trim()
    if (!label) {
      throw new ManualNodeError('label-required')
    }
    const ipv4 = input.ipv4?.trim() ?? ''
    const ipv6 = input.ipv6?.trim() ?? ''
    if (!ipv4 && !ipv6) {
      throw new ManualNodeError('address-required')
    }

    const conflict = findManualConflict({ ...input, label, ipv4, ipv6 }, currentId)
    if (conflict) {
      throw new ManualNodeError('duplicate', { conflict })
    }

    const instanceSeed = input.instanceId || `manual-${sampleID()}`
    const instanceId = instanceSeed.startsWith('cloud-') ? instanceSeed : `cloud-${instanceSeed}`
    const now = new Date().toISOString()
    const node: ManagedCloudNode = {
      instanceId,
      label,
      provider: 'manual',
      status: 'active',
      statusText: 'connected',
      region: input.region || '',
      plan: input.plan || '',
      ipv4,
      ipv6,
      createdAt: input.createdAt || now,
      ssPort: sanitizePort(input.ssPort),
      ssPassword: input.ssPassword?.trim() || undefined,
      hysteriaPort: sanitizePort(input.hysteriaPort),
      hysteriaPassword: input.hysteriaPassword?.trim() || undefined,
      hysteriaServerName: input.hysteriaServerName?.trim() || undefined,
      hysteriaInsecure: typeof input.hysteriaInsecure === 'boolean' ? input.hysteriaInsecure : undefined,
      vlessPort: sanitizePort(input.vlessPort),
      vlessUUID: input.vlessUUID?.trim() || undefined,
      vlessPublicKey: input.vlessPublicKey?.trim() || undefined,
      vlessShortId: input.vlessShortId?.trim() || undefined,
      vlessServerName: input.vlessServerName?.trim() || undefined,
      trojanPort: sanitizePort(input.trojanPort),
      trojanPassword: input.trojanPassword?.trim() || undefined,
      trojanServerName: input.trojanServerName?.trim() || undefined,
      trojanInsecure: typeof input.trojanInsecure === 'boolean' ? input.trojanInsecure : undefined,
    }
    const hasProtocol =
      (node.ssPort && node.ssPassword) ||
      (node.hysteriaPort && node.hysteriaPassword) ||
      (node.vlessPort && node.vlessUUID && node.vlessPublicKey) ||
      (node.trojanPort && node.trojanPassword)
    if (!hasProtocol) {
      throw new ManualNodeError('protocol-required')
    }
    return node
  }

  const addManualNodesInternal = (inputs: ManualNodeInput[]) => {
    const added: ManagedCloudNode[] = []
    const skipped: ManualNodeSkipEntry[] = []
    for (const input of inputs) {
      try {
        const node = createManualNode(input)
        manualNodes.value.push(node)
        added.push(node)
      } catch (error) {
        if (error instanceof ManualNodeError && error.code === 'duplicate') {
          const conflict = error.meta?.conflict as ManualNodeConflict | undefined
          const identifier =
            conflict?.value ||
            input.label ||
            input.ipv4 ||
            input.ipv6 ||
            'manual-node'
          skipped.push({
            identifier,
            reason: (conflict?.type ?? 'label') as ManualNodeConflictType,
            existingLabel: conflict?.existing.label,
            existingProvider: conflict?.existing.provider,
          })
          continue
        }
        throw error
      }
    }
    return { added, skipped }
  }

  const addManualNodes = async (
    inputs: ManualNodeInput[],
  ): Promise<{ added: ManagedCloudNode[]; skipped: ManualNodeSkipEntry[] }> => {
    if (!inputs.length) {
      return { added: [] as ManagedCloudNode[], skipped: [] as ManualNodeSkipEntry[] }
    }
    await loadManualNodes()
    const { added, skipped } = addManualNodesInternal(inputs)
    if (!added.length && skipped.length) {
      throw new ManualNodeError('duplicate', { skipped })
    }
    if (added.length) {
      await saveManualNodes()
      for (const node of added) {
        try {
          await ensureSubscriptionForNode(node)
        } catch (error) {
          logError('[CloudStore] Failed to generate subscription for manual node:', error)
        }
        markNodeStatus(node.instanceId, 'connected')
      }
      syncManualNodesIntoInstances()
    }
    return { added, skipped }
  }

  const addManualNode = async (input: ManualNodeInput) => {
    const { added } = await addManualNodes([input])
    if (!added.length) {
      throw new Error('duplicate')
    }
    return added[0]
  }

  const updateManualNode = async (instanceId: string, updates: ManualNodeInput) => {
    await loadManualNodes()
    const index = manualNodes.value.findIndex((node) => node.instanceId === instanceId)
    if (index === -1) {
      throw new Error('manual-node-not-found')
    }
    const current = manualNodes.value[index]
    const merged: ManualNodeInput = {
      instanceId,
      label: updates.label?.trim() || current.label,
      ipv4: updates.ipv4 ?? current.ipv4,
      ipv6: updates.ipv6 ?? current.ipv6,
      region: updates.region ?? current.region,
      plan: updates.plan ?? current.plan,
      ssPort: updates.ssPort ?? current.ssPort,
      ssPassword: updates.ssPassword ?? current.ssPassword,
      hysteriaPort: updates.hysteriaPort ?? current.hysteriaPort,
      hysteriaPassword: updates.hysteriaPassword ?? current.hysteriaPassword,
      vlessPort: updates.vlessPort ?? current.vlessPort,
      vlessUUID: updates.vlessUUID ?? current.vlessUUID,
      vlessPublicKey: updates.vlessPublicKey ?? current.vlessPublicKey,
      vlessShortId: updates.vlessShortId ?? current.vlessShortId,
      trojanPort: updates.trojanPort ?? current.trojanPort,
      trojanPassword: updates.trojanPassword ?? current.trojanPassword,
      createdAt: current.createdAt || new Date().toISOString(),
    }
    const updated = createManualNode(merged, instanceId)
    manualNodes.value[index] = {
      ...updated,
      provider: 'manual',
      status: 'active',
      statusText: 'connected',
      createdAt: current.createdAt || updated.createdAt,
    }
    await saveManualNodes()
    await ensureSubscriptionForNode(manualNodes.value[index])
    markNodeStatus(instanceId, 'connected')
    syncManualNodesIntoInstances()
    return manualNodes.value[index]
  }

  return {
    loadManualNodes,
    saveManualNodes,
    syncManualNodesIntoInstances,
    addManualNode,
    addManualNodes,
    updateManualNode,
  }
}
