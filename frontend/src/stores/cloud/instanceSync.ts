/**
 * Cloud Store - Instance Sync
 *
 * Handles instance refresh, auto-refresh timers, instance creation/destruction,
 * connectivity testing, IP rotation, and auto-apply scheduling.
 */


import {
  ListCloudInstances,
  CreateCloudInstance,
  CreateMultipleCloudInstances,
  DestroyCloudInstance,
  TestConnectivity,
  TestNodeDirectSpeed,
  ReadFile,
} from '@/bridge'
import { retryWithBackoff } from '@/utils/errorRecovery'
import { logError, logInfo } from '@/utils/logger'
import { notifications } from '@/utils/notification'
import { saveToOfflineCache, loadFromOfflineCache, isOnline } from '@/utils/offline'


import { CACHE_TTL, type CloudNodeStatus } from './constants'
import {
  subscriptionId,
  normalizeCloudNode,
  providerStatusToNodeStatus,
  hasUsableAddress,
  addUniquePort,
} from './helpers'

import type { ManagedCloudNode } from './types'
import type { CloudNode, CloudProvider, ConnectivityProbeRequest, ConnectivityResult } from '@/types/cloud'
import type { Ref, ShallowRef } from 'vue'

const buildConnectivityProbe = (node: CloudNode): ConnectivityProbeRequest => {
  const tcpPorts: number[] = []
  const udpPorts: number[] = []
  const targets: ConnectivityProbeRequest['targets'] = []

  if (node.ssPort) {
    addUniquePort(tcpPorts, node.ssPort)
    addUniquePort(udpPorts, node.ssPort)
    targets?.push({ name: 'shadowsocks-tcp', port: node.ssPort, network: 'tcp' })
    targets?.push({ name: 'shadowsocks-udp', port: node.ssPort, network: 'udp' })
  }
  if (node.hysteriaPort) {
    addUniquePort(udpPorts, node.hysteriaPort)
    targets?.push({ name: 'hysteria2', port: node.hysteriaPort, network: 'udp' })
  }
  if (node.vlessPort) {
    addUniquePort(tcpPorts, node.vlessPort)
    targets?.push({ name: 'vless-reality', port: node.vlessPort, network: 'tcp' })
  }
  if (node.trojanPort) {
    addUniquePort(tcpPorts, node.trojanPort)
    targets?.push({ name: 'trojan', port: node.trojanPort, network: 'tcp' })
  }

  return {
    tcpPorts,
    udpPorts,
    targets,
    probeICMP: true,
    tcpTimeoutMs: 3000,
    udpTimeoutMs: 1800,
  }
}

const getReachableEndpoints = (result: ConnectivityResult): string[] => {
  const targetStatus = result.targetStatus || {}
  const reachableTargets = Object.entries(targetStatus)
    .filter(([, status]) => status === 'open' || status === 'open_or_filtered')
    .map(([name]) => name)
  if (reachableTargets.length > 0) {
    return reachableTargets
  }

  return Object.entries(result.portsOpen || {})
    .filter(([, open]) => open)
    .map(([port]) => `port:${port}`)
}

export type InstanceSyncDeps = {
  config: { apiKey: string }
  currentProvider: Ref<CloudProvider>
  instances: ShallowRef<ManagedCloudNode[]>
  instancesUpdatedAt: Ref<number | null>
  loadingInstances: Ref<boolean>
  creatingInstance: Ref<boolean>
  destroyingInstance: Ref<string>
  manualNodes: ShallowRef<ManagedCloudNode[]>
  latencyTestResults: Ref<Record<string, number>>
  latencyUpdatedAt: Ref<number | null>
  multiDeployProgress: Ref<Map<string, import('@/types/cloud').DeployProgress>>
  appSettingsStore: {
    app: {
      kernel: { profile: string }
      autoStartKernel: boolean
    }
  }
  profilesStore: {
    getProfileById: (id: string) => IProfile | undefined
  }
  kernelApiStore: {
    running: boolean
    config: Record<string, any>
    proxies: Record<string, { name: string; type: string; now: string; all: string[] }>
    refreshProviderProxies: () => Promise<void>
    addCloudNodeToGroups: (node: ManagedCloudNode) => void
    getProxyPort: () => { port: number; proxyType: string } | undefined
  }
  subscribesStore: {
    subscribes: Array<{ id: string; [key: string]: any }>
  }
  ensureSubscriptionForNode: (node: CloudNode) => Promise<void>
  removeSubscriptionForNode: (instanceId: string) => Promise<void>
  migrateManagedNodeIdentity: (fromInstanceId: string, node: CloudNode) => Promise<boolean>
  applyNodeToProfile: (node: CloudNode, profileId?: string) => Promise<string | undefined>
  applyAllNodesToProfile: () => Promise<string[]>
  loadNodeHistory: () => Promise<unknown>
  migrateNodeHistory: (fromInstanceId: string, toInstanceId: string) => Promise<boolean>
  recordConnectivitySample: (
    instanceId: string,
    status: import('@/types/cloud').ConnectivityStatus,
    result?: ConnectivityResult,
  ) => Promise<void>
  recordSpeedSample: (
    instanceId: string,
    sample: { speedMbps?: number; status: 'ok' | 'partial' | 'timeout' | 'error'; error?: string },
  ) => Promise<void>
  loadManualNodes: () => Promise<ManagedCloudNode[]>
  syncManualNodesIntoInstances: () => void
  saveManualNodes: (...args: any[]) => any
  ensureRegionAvailability: (region: string, force?: boolean) => Promise<string[]>
  updateProtocolHealthFromConnectivity: (node: CloudNode, result: ConnectivityResult) => Promise<void>
  reloadKernel: (reason: string, options?: { allowStartWhenStopped?: boolean }) => Promise<void>
  markNodeStatus: (instanceId: string, status: CloudNodeStatus) => void
}

export function createInstanceSync(deps: InstanceSyncDeps) {
  const {
    config,
    currentProvider,
    instances,
    instancesUpdatedAt,
    loadingInstances,
    creatingInstance,
    destroyingInstance,
    manualNodes,
    multiDeployProgress,
    appSettingsStore,
    profilesStore,
    kernelApiStore,
    ensureSubscriptionForNode,
    removeSubscriptionForNode,
    migrateManagedNodeIdentity,
    applyNodeToProfile,
    applyAllNodesToProfile,
    loadNodeHistory,
    migrateNodeHistory,
    loadManualNodes,
    syncManualNodesIntoInstances,
    saveManualNodes,
    ensureRegionAvailability,
    updateProtocolHealthFromConnectivity,
    reloadKernel,
    markNodeStatus,
  } = deps

  let autoRefreshTimer: ReturnType<typeof setInterval> | null = null
  const autoApplyTimers = new Map<string, ReturnType<typeof setInterval>>()
  let refreshingInstances = false

  const isSpeedTimeoutError = (error: string | undefined): boolean => {
    if (!error) {
      return false
    }

    const normalized = error.toLowerCase()
    return normalized.includes('timeout')
      || normalized.includes('timed out')
      || normalized.includes('deadline exceeded')
  }

  const getSpeedFailureStatus = (error: string | undefined): 'timeout' | 'error' => {
    return isSpeedTimeoutError(error) ? 'timeout' : 'error'
  }

  const isCacheValid = (timestamp: number | null, ttl: number): boolean => {
    if (!timestamp) return false
    return Date.now() - timestamp < ttl
  }

  const isInstancesCacheValid = () => isCacheValid(instancesUpdatedAt.value, CACHE_TTL.instances)
  const isLatencyCacheValid = () => isCacheValid(deps.latencyUpdatedAt.value, CACHE_TTL.latency)

  const stopAutoRefresh = () => {
    if (autoRefreshTimer !== null) {
      clearInterval(autoRefreshTimer)
      autoRefreshTimer = null
      logInfo('[CloudStore] Stopped auto refresh timer')
    }
  }

  function stopAutoApplyTimer(instanceId: string) {
    const timer = autoApplyTimers.get(instanceId)
    if (timer) {
      clearInterval(timer)
      autoApplyTimers.delete(instanceId)
      logInfo(`[CloudStore] Stopped auto apply timer for instance: ${instanceId}`)
    }
  }

  const clearAllTimers = () => {
    stopAutoRefresh()
    const instanceIds = Array.from(autoApplyTimers.keys())
    instanceIds.forEach(id => stopAutoApplyTimer(id))
    logInfo('[CloudStore] Cleared all timers')
  }

  function scheduleAutoApply(instanceId: string) {
    if (autoApplyTimers.has(instanceId)) {
      return
    }

    let attempts = 0
    const run = async () => {
      const node = instances.value.find((n) => n.instanceId === instanceId)
      if (!node) {
        stopAutoApplyTimer(instanceId)
        return
      }

      if (!hasUsableAddress(node)) {
        attempts += 1
        if (attempts % 3 === 0) {
          await refreshInstances(true).catch(() => undefined)
        }
        if (attempts > 60) {
          logError('[CloudStore] Auto apply timed out waiting for usable address:', node.label)
          stopAutoApplyTimer(instanceId)
        }
        return
      }

      try {
        logInfo('[CloudStore] Auto applying node via scheduler:', node.label)
        await ensureSubscriptionForNode(node)
        await applyNodeToProfile(node)
        markNodeStatus(instanceId, 'connected')
        instancesUpdatedAt.value = Date.now()
        if (kernelApiStore.running) {
          await kernelApiStore.refreshProviderProxies().catch((error) =>
            logError('[CloudStore] Failed to refresh provider proxies after scheduled apply:', error),
          )
        }
      } catch (error) {
        logError('[CloudStore] Scheduled auto apply failed:', node.label, error)
      } finally {
        stopAutoApplyTimer(instanceId)
      }
    }

    const timer = setInterval(run, 5_000)
    autoApplyTimers.set(instanceId, timer)
    run()
  }

  const providerRequiresApiKey = () => currentProvider.value !== 'ssh'

  const refreshInstances = async (silent = false, force = false) => {
    if (!force && isInstancesCacheValid() && instances.value.length > 0) {
      logInfo('[CloudStore] Using cached instances data')
      return
    }

    if (!isOnline.value) {
      const cached = loadFromOfflineCache<ManagedCloudNode[]>('nodes')
      if (cached) {
        instances.value = cached
        instancesUpdatedAt.value = Date.now()
        await loadManualNodes()
        syncManualNodesIntoInstances()
        logInfo('[CloudStore] Loaded instances from offline cache')
        return
      }
    }

    if (refreshingInstances) {
      logInfo('[CloudStore] refreshInstances skipped: another refresh is in progress')
      return
    }
    refreshingInstances = true

    if (!silent) {
      loadingInstances.value = true
    }
    try {
      await loadNodeHistory()
      const rawNodes = await retryWithBackoff(
        () => ListCloudInstances(),
        'ListCloudInstances',
        { maxAttempts: 3, baseDelay: 1000 }
      )
      const normalizedNodes = rawNodes
        .map((node) => normalizeCloudNode(node, currentProvider.value))
      const filteredNodes = normalizedNodes.filter((node) => node.instanceId)
      const nodesToProcess = filteredNodes
      const migratedInstanceIds = new Set<string>()

      for (const node of nodesToProcess) {
        const replacedInstanceId = node.replacedInstanceId?.trim()
        if (!replacedInstanceId || replacedInstanceId === node.instanceId) {
          continue
        }

        try {
          await migrateManagedNodeIdentity(replacedInstanceId, node)
          await migrateNodeHistory(replacedInstanceId, node.instanceId)
          migratedInstanceIds.add(replacedInstanceId)
          logInfo(
            `[CloudStore] Migrated replaced cloud instance ${replacedInstanceId} -> ${node.instanceId} (${node.label})`,
          )
        } catch (error) {
          logError(
            '[CloudStore] Failed to migrate replaced cloud instance:',
            replacedInstanceId,
            node.instanceId,
            error,
          )
        }
      }

      await Promise.all(
        nodesToProcess.map((node) => ensureRegionAvailability(node.region || '').catch(() => [])),
      )

      // Store previous instances for comparison
      const previousInstances = instances.value

      const previousMap = new Map(instances.value.map((node) => [node.instanceId, node]))
      const enriched: ManagedCloudNode[] = nodesToProcess.map((node) => {
        const prev = previousMap.get(node.instanceId)
          || (node.replacedInstanceId ? previousMap.get(node.replacedInstanceId) : undefined)
        const previousStatus = prev?.statusText || 'unknown'
        const providerStatus = providerStatusToNodeStatus(node.status)
        let statusText: CloudNodeStatus = previousStatus

        if (providerStatus === 'connected') {
          statusText = 'connected'
        } else if (previousStatus === 'unknown' && providerStatus !== 'unknown') {
          statusText = providerStatus
        } else if (previousStatus === 'pending' && providerStatus === 'applying') {
          statusText = 'applying'
        } else if (previousStatus !== 'error' && providerStatus === 'error') {
          statusText = 'error'
        }

        return {
          ...node,
          statusText,
          ...(prev?.connectivityStatus ? { connectivityStatus: prev.connectivityStatus } : {}),
          ...(prev?.connectivityTesting ? { connectivityTesting: prev.connectivityTesting } : {}),
          ...(prev?.lastConnectivityResult ? { lastConnectivityResult: prev.lastConnectivityResult } : {}),
          // Preserve speed test data across refreshes
          ...(prev?.speedMs !== undefined ? { speedMs: prev.speedMs } : {}),
          ...(prev?.speedMbps !== undefined ? { speedMbps: prev.speedMbps } : {}),
          ...(prev?.speedError ? { speedError: prev.speedError } : {}),
          ...(prev?.speedTesting ? { speedTesting: prev.speedTesting } : {}),
        }
      })

      const activeProfile = profilesStore.getProfileById(appSettingsStore.app.kernel.profile)
      if (activeProfile) {
        const subscriptionIds = new Set<string>()
        activeProfile.outbounds?.forEach((outbound: any) => {
          const children = outbound.outbounds || []
          children.forEach((child: any) => child?.id && subscriptionIds.add(child.id))
        })
        enriched.forEach((node) => {
          const subId = subscriptionId(node.instanceId)
          const legacySubId = node.replacedInstanceId ? subscriptionId(node.replacedInstanceId) : ''
          if ((subscriptionIds.has(subId) || (!!legacySubId && subscriptionIds.has(legacySubId))) && node.statusText !== 'applying') {
            node.statusText = node.statusText === 'pending' ? 'pending' : 'connected'
          }
        })
      }

      // Preserve in-use nodes that the provider API didn't return this cycle.
      // Only remove a managed node when a verified list call explicitly omits it
      // AND it's not referenced by any existing subscription / active profile —
      // otherwise a partial / region-scoped / transiently-filtered response would
      // wipe working nodes out of the UI.
      const enrichedIds = new Set(
        enriched.filter((node) => node.instanceId).map((node) => node.instanceId),
      )
      const subscribedInstanceIds = new Set<string>(
        deps.subscribesStore.subscribes
          .filter((sub: any) => typeof sub.id === 'string' && sub.id.startsWith('cloud-'))
          .map((sub: any) => String(sub.id).slice('cloud-'.length)),
      )
      const profileSubscriptionChildIds = new Set<string>()
      const preMergeProfile = profilesStore.getProfileById(appSettingsStore.app.kernel.profile)
      preMergeProfile?.outbounds?.forEach((outbound: any) => {
        ;(outbound.outbounds || []).forEach((child: any) => {
          if (typeof child?.id === 'string' && child.id.startsWith('cloud-')) {
            profileSubscriptionChildIds.add(child.id.slice('cloud-'.length))
          }
        })
      })
      const isInUse = (instanceId: string): boolean =>
        !!instanceId
        && (subscribedInstanceIds.has(instanceId) || profileSubscriptionChildIds.has(instanceId))

      const retainedFromPrevious: ManagedCloudNode[] = previousInstances.filter((prev) => {
        if (!prev.instanceId) return false
        if (enrichedIds.has(prev.instanceId)) return false
        if (migratedInstanceIds.has(prev.instanceId)) return false
        return isInUse(prev.instanceId)
      }).map((node) => ({
        ...node,
        // Mark as unknown so UI can indicate the node wasn't in the latest list,
        // but don't flip to 'error' / remove it automatically.
        statusText: node.statusText === 'error' ? 'error' : 'unknown',
      }))
      if (retainedFromPrevious.length > 0) {
        logInfo(
          `[CloudStore] Retained ${retainedFromPrevious.length} in-use node(s) missing from provider list:`,
          retainedFromPrevious.map((n) => n.label || n.instanceId),
        )
      }

      const merged = [...enriched, ...retainedFromPrevious]
      instances.value = merged
      instancesUpdatedAt.value = Date.now()

      saveToOfflineCache('nodes', merged)

      logInfo(`[CloudStore] Set instances.value to ${merged.length} nodes (${enriched.length} from provider + ${retainedFromPrevious.length} retained):`, JSON.stringify(merged.map(n => ({ id: n.instanceId, label: n.label, ipv4: n.ipv4 }))))

      await loadManualNodes()
      syncManualNodesIntoInstances()

      // schedule auto-apply for nodes that are not fully connected yet
      enriched.forEach((node) => {
        if (!node.instanceId) {
          return
        }
        if (hasUsableAddress(node) && node.statusText === 'connected') {
          stopAutoApplyTimer(node.instanceId)
        } else {
          scheduleAutoApply(node.instanceId)
        }
      })

      // Create subscriptions for all nodes with IP addresses
      await Promise.all(
        enriched
          .filter((node) => node.instanceId && (node.ipv4 || node.ipv6))
          .map((node) => ensureSubscriptionForNode(node).catch((error) => {
            logError('[CloudStore] Failed to create subscription for node:', node.label, error)
            return undefined
          })),
      )

      // Auto-apply nodes that were pending and now have IP addresses
      const nodesToAutoApply = enriched.filter((node) => {
        const oldNode = previousInstances.find((n) => n.instanceId === node.instanceId)
        const hasAddress = hasUsableAddress(node)
        if (!hasAddress) return false

        const wasMissingAddress = !oldNode || (!oldNode.ipv4 && !oldNode.ipv6)
        if (!wasMissingAddress) return false

        const wasPendingBefore = !oldNode || oldNode.statusText === 'pending' || oldNode.statusText === 'applying'
        const isPendingNow = node.statusText === 'pending' || node.statusText === 'applying'
        const providerJustConnected = node.statusText === 'connected' && wasPendingBefore

        return isPendingNow || providerJustConnected
      })

      let shouldReloadKernel = false
      for (const node of nodesToAutoApply) {
        try {
          logInfo('[CloudStore] Auto-applying newly ready node:', node.label)
          await applyNodeToProfile(node)

          kernelApiStore.addCloudNodeToGroups(node)
          logInfo('[CloudStore] Optimistically added cloud node proxies to groups:', node.label)

          node.statusText = 'connected'
          instances.value = instances.value.map((n) =>
            n.instanceId === node.instanceId ? node : n,
          )
          instancesUpdatedAt.value = Date.now()
          shouldReloadKernel = true
          logInfo('[CloudStore] Successfully auto-applied node:', node.label)
        } catch (error) {
          logError('[CloudStore] Auto-apply failed for node:', node.label, error)
          node.statusText = 'pending'
          instances.value = instances.value.map((n) =>
            n.instanceId === node.instanceId ? node : n,
          )
          instancesUpdatedAt.value = Date.now()
        }
      }

      // Only prune subscriptions for previousInstances that the provider list
      // verifiably omitted AND that aren't still being used by the app. This
      // prevents transient / partial list responses from wiping subscriptions
      // of nodes the user actively has deployed.
      const removedNodes = previousInstances.filter(
        (prev) =>
          prev.instanceId &&
          !migratedInstanceIds.has(prev.instanceId) &&
          !nodesToProcess.some((node) => node.instanceId === prev.instanceId) &&
          !isInUse(prev.instanceId),
      )
      if (removedNodes.length > 0) {
        await Promise.all(removedNodes.map((node) => removeSubscriptionForNode(node.instanceId)))
      }

      // Do NOT auto-delete "stale" cloud-* subscriptions here: absence from the
      // provider list is not sufficient proof that a node was deleted (see
      // feedback memory on retaining in-use nodes). Subscriptions are cleaned
      // up explicitly via destroyInstance / user-initiated delete.

      // Ensure there is at least one active cloud subscription when nodes exist
      const refreshedProfile = profilesStore.getProfileById(appSettingsStore.app.kernel.profile)
      const hasCloudSubscription =
        !!refreshedProfile &&
        refreshedProfile.outbounds?.some((outbound: any) =>
          Array.isArray(outbound.outbounds) &&
          outbound.outbounds.some(
            (child: any) => typeof child?.id === 'string' && child.id.startsWith('cloud-'),
          ),
        )

      if (!hasCloudSubscription) {
        const candidate = enriched.find((node) => node.instanceId && (node.ipv4 || node.ipv6))
        if (candidate) {
          try {
            logInfo('[CloudStore] No active cloud subscription found, applying node:', candidate.label)
            await applyNodeToProfile(candidate)
            shouldReloadKernel = true
            candidate.statusText = 'connected'
            instances.value = instances.value.map((n) =>
              n.instanceId === candidate.instanceId ? candidate : n,
            )
            instancesUpdatedAt.value = Date.now()
            logInfo('[CloudStore] Applied node as default subscription:', candidate.label)
          } catch (error) {
            logError('[CloudStore] Failed to apply default node:', candidate.label, error)
          }
        }
      }

      const bulkApplied = await applyAllNodesToProfile().catch((error) => {
        logError('[CloudStore] Failed to auto-apply all nodes:', error)
        return [] as string[]
      })

      if (!bulkApplied.length) {
        if (shouldReloadKernel) {
          try {
            await reloadKernel('refresh-instances')
          } catch (error) {
            logError('[CloudStore] Failed to reload kernel after refresh apply:', error)
          }
        } else if (kernelApiStore.running) {
          await kernelApiStore.refreshProviderProxies().catch((error) =>
            logError('[CloudStore] Failed to refresh provider proxies:', error),
          )
        }
      }
    } catch (error) {
      logError('[CloudStore] refreshInstances error:', error)

      const cached = loadFromOfflineCache<ManagedCloudNode[]>('nodes')
      if (cached) {
        instances.value = cached
        instancesUpdatedAt.value = Date.now()
        await loadManualNodes()
        syncManualNodesIntoInstances()
        logInfo('[CloudStore] Failed to fetch instances, using offline cache')
      } else {
        throw error
      }
    } finally {
      refreshingInstances = false
      if (!silent) {
        loadingInstances.value = false
      }
    }
  }

  const startAutoRefresh = (refreshImmediately = false) => {
    if (providerRequiresApiKey() && (!config.apiKey || config.apiKey.trim() === '')) {
      stopAutoRefresh()
      return
    }
    if (autoRefreshTimer !== null) {
      return
    }

    const runRefresh = () => {
      if (providerRequiresApiKey() && (!config.apiKey || config.apiKey.trim() === '')) {
        stopAutoRefresh()
        return
      }
      if (loadingInstances.value || creatingInstance.value || destroyingInstance.value) {
        return
      }
      refreshInstances(true, false).catch((error) => {
        logError('[CloudStore] Auto refresh failed:', error)
      })
    }

    autoRefreshTimer = setInterval(runRefresh, CACHE_TTL.instancesBackground)
    logInfo('[CloudStore] Started optimized auto refresh timer (5min interval)')
    if (refreshImmediately) {
      runRefresh()
    }
  }

  const createInstance = async (options: { label: string; region: string; plan: string }) => {
    creatingInstance.value = true
    try {
      const rawNode = await retryWithBackoff(
        () => CreateCloudInstance(options),
        'CreateCloudInstance',
        { maxAttempts: 3, baseDelay: 2000 }
      )
      const node = normalizeCloudNode(rawNode, currentProvider.value)
      if (node.instanceId) {
        await ensureRegionAvailability(node.region || '')
        const cloudNode: ManagedCloudNode = { ...node, statusText: 'applying' }
        instances.value = [cloudNode, ...instances.value.filter((n) => n.instanceId !== node.instanceId)]
        instancesUpdatedAt.value = Date.now()
        syncManualNodesIntoInstances()
        startAutoRefresh(true)

        if (!cloudNode.ipv4 && !cloudNode.ipv6) {
          logInfo('[CloudStore] Node created without IP, will retry subscription creation after refresh')
          cloudNode.statusText = 'pending'
          instances.value = instances.value.map((n) =>
            n.instanceId === cloudNode.instanceId ? cloudNode : n
          )
          setTimeout(() => refreshInstances(true).catch(() => undefined), 5000)
          return node
        }

        await ensureSubscriptionForNode(cloudNode)

        let applySuccess = false
        try {
          await applyNodeToProfile(cloudNode)
          applySuccess = true
          logInfo('[CloudStore] Successfully applied new node to profile:', cloudNode.label)

          kernelApiStore.addCloudNodeToGroups(cloudNode)
          logInfo('[CloudStore] Optimistically added cloud node proxies to groups:', cloudNode.label)

          cloudNode.statusText = 'connected'
          instances.value = instances.value.map((n) =>
            n.instanceId === cloudNode.instanceId ? cloudNode : n
          )
          instancesUpdatedAt.value = Date.now()

          notifications.deploymentComplete(cloudNode.label)
        } catch (error) {
          logError('[CloudStore] Auto-apply failed for new node:', cloudNode.label, error)
          cloudNode.statusText = 'pending'
          instances.value = instances.value.map((n) =>
            n.instanceId === cloudNode.instanceId ? cloudNode : n
          )
          instancesUpdatedAt.value = Date.now()

          notifications.deploymentFailed(cloudNode.label, error instanceof Error ? error.message : String(error))
        }

        if (applySuccess) {
          try {
            await reloadKernel('create-instance')

            logInfo('[CloudStore] Auto-testing connectivity for new node:', cloudNode.label)
            testNodeConnectivity(cloudNode.instanceId).catch((error) => {
              logError('[CloudStore] Auto connectivity test failed:', error)
            })
          } catch (error) {
            logError('[CloudStore] Kernel start/restart failed after deployment:', error)
          }
        }
      }
      return node
    } finally {
      creatingInstance.value = false
    }
  }

  const createSSHInstance = async (extra: Record<string, string>, label?: string) => {
    creatingInstance.value = true
    try {
      const options = {
        label: label || `ssh-${extra.host || 'node'}`,
        region: '',
        plan: '',
        extra,
      }
      const rawNode = await CreateCloudInstance(options)
      const node = normalizeCloudNode(rawNode, 'ssh')

      if (node.instanceId) {
        const cloudNode: ManagedCloudNode = { ...node, statusText: 'connected' }
        instances.value = [cloudNode, ...instances.value.filter((n) => n.instanceId !== node.instanceId)]
        instancesUpdatedAt.value = Date.now()
        syncManualNodesIntoInstances()

        await ensureSubscriptionForNode(cloudNode)

        try {
          await applyNodeToProfile(cloudNode)
          cloudNode.statusText = 'connected'
          notifications.deploymentComplete(cloudNode.label)
        } catch (error) {
          logError('[CloudStore] Auto-apply failed for SSH node:', cloudNode.label, error)
          cloudNode.statusText = 'pending'
        }

        instances.value = instances.value.map((n) =>
          n.instanceId === cloudNode.instanceId ? cloudNode : n
        )
        instancesUpdatedAt.value = Date.now()
      }

      return node
    } finally {
      creatingInstance.value = false
    }
  }

  const createMultipleInstances = async (configs: Array<{ label: string; region: string; plan: string; extra?: Record<string, string> }>) => {
    multiDeployProgress.value = new Map()
    try {
      const results = await CreateMultipleCloudInstances(configs)
      await refreshInstances(true)
      return results
    } catch (error) {
      logError('[CloudStore] Multi-deploy failed:', error)
      throw error
    }
  }

  const destroyInstance = async (instanceId: string) => {
    destroyingInstance.value = instanceId
    try {
      stopAutoApplyTimer(instanceId)
      await loadManualNodes()
      const manualIndex = manualNodes.value.findIndex((node) => node.instanceId === instanceId)
      if (manualIndex !== -1) {
        manualNodes.value.splice(manualIndex, 1)
        await saveManualNodes()
        instances.value = instances.value.filter((node) => node.instanceId !== instanceId)
        instancesUpdatedAt.value = Date.now()
        await removeSubscriptionForNode(instanceId)
        syncManualNodesIntoInstances()
        return
      }
      await DestroyCloudInstance(instanceId)
      instances.value = instances.value.filter((node) => node.instanceId !== instanceId)
      instancesUpdatedAt.value = Date.now()
      await removeSubscriptionForNode(instanceId)
      syncManualNodesIntoInstances()
    } finally {
      destroyingInstance.value = ''
    }
  }

  const rotateIP = async (instanceId: string) => {
    const node = instances.value.find((item) => item.instanceId === instanceId) ||
                 manualNodes.value.find((item) => item.instanceId === instanceId)

    if (!node) {
      throw new Error('Node not found for IP rotation')
    }

    const isManual = manualNodes.value.some((n) => n.instanceId === instanceId)
    if (isManual) {
      throw new Error('Manual nodes cannot rotate IP automatically. Please edit the node to update IP address.')
    }

    const nodeConfig = {
      label: node.label,
      region: node.region || '',
      plan: node.plan || '',
    }

    logInfo('[CloudStore] Rotating IP for node:', node.label, nodeConfig)

    notifications.info('IP Rotation Started', `Rotating IP for ${node.label}...`)

    try {
      await destroyInstance(instanceId)

      logInfo('[CloudStore] Creating replacement instance with same configuration')
      const newNode = await createInstance(nodeConfig)

      logInfo('[CloudStore] IP rotation completed. New node:', newNode.instanceId)

      notifications.rotationComplete(node.label)

      return newNode
    } catch (error) {
      notifications.rotationFailed(node.label, error instanceof Error ? error.message : String(error))
      throw error
    }
  }

  const testNodeConnectivity = async (instanceId: string) => {
    const node = instances.value.find((item) => item.instanceId === instanceId) ||
                 manualNodes.value.find((item) => item.instanceId === instanceId)

    if (!node) {
      logError('[CloudStore] Node not found for connectivity test:', instanceId)
      return
    }

    const testIP = node.ipv4 || node.ipv6
    if (!testIP) {
      logError('[CloudStore] No IP address available for node:', instanceId)
      node.connectivityStatus = 'unknown'
      return
    }

    const probe = buildConnectivityProbe(node)

    node.connectivityTesting = true
    node.connectivityStatus = 'testing'
    logInfo(`[CloudStore] Testing connectivity to ${testIP}:`, probe)

    try {
      const result = await retryWithBackoff(
        () => TestConnectivity(testIP, probe),
        'TestConnectivity',
        { maxAttempts: 2, baseDelay: 1000 }
      )
      logInfo('[CloudStore] Connectivity test result:', result)

      node.connectivityStatus = result.status
      node.lastConnectivityResult = result
      node.connectivityTesting = false
      await deps.recordConnectivitySample(instanceId, result.status, result)
      await updateProtocolHealthFromConnectivity(node, result)

      if (result.status === 'blocked') {
        notifications.connectivityBlocked(node.label)
      } else if (result.status === 'reachable') {
        notifications.connectivityRestored(node.label)
      }
    } catch (error) {
      logError('[CloudStore] Connectivity test failed:', error)
      node.connectivityStatus = 'unknown'
      node.connectivityTesting = false
      await deps.recordConnectivitySample(instanceId, 'unknown')

      notifications.error(
        'Connectivity Test Failed',
        `Failed to test connectivity for ${node.label}: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  }

  const testAllNodesConnectivity = async () => {
    const allNodes = [...instances.value, ...manualNodes.value]
    const testPromises = allNodes.map(node => testNodeConnectivity(node.instanceId))
    await Promise.allSettled(testPromises)
    logInfo('[CloudStore] Completed connectivity tests for all nodes')
  }

  const patchNode = (instanceId: string, patch: Partial<ManagedCloudNode>) => {
    const idx = instances.value.findIndex((n) => n.instanceId === instanceId)
    if (idx !== -1) {
      instances.value = instances.value.map((n, i) =>
        i === idx ? { ...n, ...patch } : n
      )
      return
    }
    const mIdx = manualNodes.value.findIndex((n) => n.instanceId === instanceId)
    if (mIdx !== -1) {
      manualNodes.value = manualNodes.value.map((n, i) =>
        i === mIdx ? { ...n, ...patch } : n
      )
    }
  }

  /**
   * Get the full outbound objects for a node from its subscription file.
   */
  const getNodeOutbounds = async (instanceId: string): Promise<Record<string, any>[]> => {
    const subPath = `data/subscribes/${subscriptionId(instanceId)}.json`
    try {
      const content = await ReadFile(subPath)
      const data = JSON.parse(content) as { outbounds?: Record<string, any>[] }
      return (data.outbounds || []).filter((o: Record<string, any>) => !!o.tag)
    } catch {
      return []
    }
  }

  const testNodeSpeedTest = async (instanceId: string) => {
    const node = instances.value.find((item) => item.instanceId === instanceId) ||
                 manualNodes.value.find((item) => item.instanceId === instanceId)
    if (!node) return

    patchNode(instanceId, { speedTesting: true, speedMbps: undefined, speedError: undefined })

    // Read outbounds directly from this node's subscription file
    const outbounds = await getNodeOutbounds(instanceId)
    if (!outbounds.length) {
      logError(`[CloudStore] Speed test skipped for ${node.label}: no outbound config`)
      const error = 'no outbound config'
      patchNode(instanceId, { speedMbps: -1, speedError: error, speedTesting: false })
      await deps.recordSpeedSample(instanceId, { status: 'error', error })
      return
    }

    try {
      // Test directly via temporary sing-box — no dependency on main kernel
      const result = await TestNodeDirectSpeed(outbounds, 15)
      if (result.status === 'ok' || result.status === 'partial') {
        const mbps = Math.round(result.speedMbps * 100) / 100
        logInfo(`[CloudStore] ${node.label}: ${mbps} Mbps`)
        patchNode(instanceId, {
          speedMbps: mbps,
          speedError: result.status === 'partial' ? (result.error || 'partial sample') : undefined,
          speedTesting: false,
        })
        await deps.recordSpeedSample(instanceId, {
          speedMbps: mbps,
          status: result.status === 'partial' ? 'partial' : 'ok',
          error: result.status === 'partial' ? result.error : undefined,
        })
        return
      }

      const error = typeof result.error === 'string' && result.error.trim().length > 0
        ? result.error.trim()
        : 'speed test failed'
      patchNode(instanceId, { speedMbps: -1, speedError: error, speedTesting: false })
      await deps.recordSpeedSample(instanceId, {
        status: getSpeedFailureStatus(error),
        error,
      })
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error)
      patchNode(instanceId, { speedMbps: -1, speedError: reason, speedTesting: false })
      await deps.recordSpeedSample(instanceId, {
        status: getSpeedFailureStatus(reason),
        error: reason,
      })
    }
  }

  const testAllNodesSpeed = async () => {
    const allNodes = [...instances.value, ...manualNodes.value]
    if (!allNodes.length) return

    // Mark all as testing
    allNodes.forEach(node => {
      patchNode(node.instanceId, { speedTesting: true, speedMbps: undefined, speedError: undefined })
    })

    // Test each node sequentially — each spawns its own temporary sing-box
    for (const node of allNodes) {
      const outbounds = await getNodeOutbounds(node.instanceId)
      if (!outbounds.length) {
        logInfo(`[CloudStore] Skipping ${node.label}: no outbound config`)
        const error = 'no outbound config'
        patchNode(node.instanceId, { speedMbps: -1, speedError: error, speedTesting: false })
        await deps.recordSpeedSample(node.instanceId, {
          status: 'error',
          error,
        })
        continue
      }
      try {
        const result = await TestNodeDirectSpeed(outbounds, 15)
        if (result.status === 'ok' || result.status === 'partial') {
          const mbps = Math.round(result.speedMbps * 100) / 100
          logInfo(`[CloudStore] ${node.label}: ${mbps} Mbps`)
          patchNode(node.instanceId, {
            speedMbps: mbps,
            speedError: result.status === 'partial' ? (result.error || 'partial sample') : undefined,
            speedTesting: false,
          })
          await deps.recordSpeedSample(node.instanceId, {
            speedMbps: mbps,
            status: result.status === 'partial' ? 'partial' : 'ok',
            error: result.status === 'partial' ? result.error : undefined,
          })
          continue
        }

        const error = typeof result.error === 'string' && result.error.trim().length > 0
          ? result.error.trim()
          : 'speed test failed'
        patchNode(node.instanceId, { speedMbps: -1, speedError: error, speedTesting: false })
        await deps.recordSpeedSample(node.instanceId, {
          status: getSpeedFailureStatus(error),
          error,
        })
      } catch (error) {
        const reason = error instanceof Error ? error.message : String(error)
        patchNode(node.instanceId, { speedMbps: -1, speedError: reason, speedTesting: false })
        await deps.recordSpeedSample(node.instanceId, {
          status: getSpeedFailureStatus(reason),
          error: reason,
        })
      }
    }

    logInfo('[CloudStore] Speed test completed')
  }

  const verifyNodeConnectivity = async (node: ManagedCloudNode) => {
    logInfo('[CloudStore] Verifying end-to-end connectivity for:', node.label)

    let kernelReady = false
    for (let i = 0; i < 15; i++) {
      if (kernelApiStore.running) {
        kernelReady = true
        break
      }
      await new Promise(resolve => setTimeout(resolve, 2000))
    }

    if (!kernelReady) {
      logError('[CloudStore] Kernel not running, skipping proxy verification')
      node.statusText = 'pending'
      notifications.error('\u8fde\u63a5\u9a8c\u8bc1\u5931\u8d25', `${node.label}: sing-box \u5185\u6838\u672a\u8fd0\u884c`)
      return false
    }

    try {
      const testIP = node.ipv4 || node.ipv6
      if (!testIP) {
        logError('[CloudStore] No IP for verification:', node.label)
        return false
      }

      const probe = buildConnectivityProbe(node)
      const result = await TestConnectivity(testIP, probe)
      node.lastConnectivityResult = result
      await deps.recordConnectivitySample(node.instanceId, result.status, result)
      await updateProtocolHealthFromConnectivity(node, result)

      if (result.status === 'reachable') {
        node.statusText = 'connected'
        node.connectivityStatus = 'reachable'
        logInfo('[CloudStore] Node verified reachable:', node.label)
        notifications.connectivityRestored(node.label)
        return true
      }

      const reachableEndpoints = getReachableEndpoints(result)

      if (reachableEndpoints.length > 0) {
        node.statusText = 'connected'
        node.connectivityStatus = 'icmp_blocked'
        logInfo('[CloudStore] Node partially reachable:', reachableEndpoints)
        notifications.connectivityRestored(node.label)
        return true
      }

      node.statusText = 'error'
      node.connectivityStatus = 'blocked'
      logError('[CloudStore] Node blocked:', node.label)
      notifications.connectivityBlocked(node.label)
      return false
    } catch (error) {
      logError('[CloudStore] Verification failed for:', node.label, error)
      node.connectivityStatus = 'unknown'
      await deps.recordConnectivitySample(node.instanceId, 'unknown')
      return false
    } finally {
      instances.value = instances.value.map((n) =>
        n.instanceId === node.instanceId ? { ...node } : n
      )
      instancesUpdatedAt.value = Date.now()
    }
  }

  return {
    refreshInstances,
    startAutoRefresh,
    stopAutoRefresh,
    clearAllTimers,
    isInstancesCacheValid,
    isLatencyCacheValid,
    createInstance,
    createSSHInstance,
    createMultipleInstances,
    destroyInstance,
    rotateIP,
    testNodeConnectivity,
    testAllNodesConnectivity,
    testNodeSpeedTest,
    testAllNodesSpeed,
    verifyNodeConnectivity,
  }
}
