/**
 * Cloud Store - Instance Sync
 *
 * Handles instance refresh, auto-refresh timers, instance creation/destruction,
 * connectivity testing, IP rotation, and auto-apply scheduling.
 */

import type { Ref, ShallowRef } from 'vue'

import {
  ListCloudInstances,
  CreateCloudInstance,
  CreateMultipleCloudInstances,
  DestroyCloudInstance,
  TestConnectivity,
} from '@/bridge'
import { retryWithBackoff } from '@/utils/errorRecovery'
import { logError, logInfo } from '@/utils/logger'
import { notifications } from '@/utils/notification'
import { saveToOfflineCache, loadFromOfflineCache, isOnline } from '@/utils/offline'

import type { CloudNode, CloudProvider, ConnectivityProbeRequest, ConnectivityResult } from '@/types/cloud'

import { CACHE_TTL, type CloudNodeStatus } from './constants'
import {
  parseJSON,
  subscriptionId,
  normalizeCloudNode,
  providerStatusToNodeStatus,
  hasUsableAddress,
  addUniquePort,
  isReachableTargetStatus,
} from './helpers'

import type { ManagedCloudNode } from './types'

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
    refreshProviderProxies: () => Promise<void>
    addCloudNodeToGroups: (node: ManagedCloudNode) => void
  }
  ensureSubscriptionForNode: (node: CloudNode) => Promise<void>
  removeSubscriptionForNode: (instanceId: string) => Promise<void>
  applyNodeToProfile: (node: CloudNode, profileId?: string) => Promise<string | undefined>
  applyAllNodesToProfile: () => Promise<string[]>
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
    applyNodeToProfile,
    applyAllNodesToProfile,
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

  const ensureFlag = (flag: boolean, data: string) => {
    if (!flag) throw new Error(data)
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

  const refreshInstances = async (silent = false, force = false) => {
    if (!config.apiKey || config.apiKey.trim() === '') {
      instances.value = []
      instancesUpdatedAt.value = Date.now()
      return
    }

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
      const res = await retryWithBackoff(
        () => ListCloudInstances(),
        'ListCloudInstances',
        { maxAttempts: 3, baseDelay: 1000 }
      )
      ensureFlag(res.flag, res.data)
      const rawNodes = parseJSON<Record<string, any>[]>(res.data, [])
      const normalizedNodes = rawNodes
        .map((node) => normalizeCloudNode(node, currentProvider.value))
      const filteredNodes = normalizedNodes.filter((node) => node.instanceId)
      const nodesToProcess = filteredNodes

      await Promise.all(
        nodesToProcess.map((node) => ensureRegionAvailability(node.region || '').catch(() => [])),
      )

      // Store previous instances for comparison
      const previousInstances = instances.value

      const statusMap = new Map(instances.value.map((node) => [node.instanceId, node.statusText || 'unknown']))
      const enriched: ManagedCloudNode[] = nodesToProcess.map((node) => {
        const previousStatus = statusMap.get(node.instanceId) || 'unknown'
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
          if (subscriptionIds.has(subId) && node.statusText !== 'applying') {
            node.statusText = node.statusText === 'pending' ? 'pending' : 'connected'
          }
        })
      }

      instances.value = enriched
      instancesUpdatedAt.value = Date.now()

      saveToOfflineCache('nodes', enriched)

      logInfo(`[CloudStore] Set instances.value to ${enriched.length} nodes:`, JSON.stringify(enriched.map(n => ({ id: n.instanceId, label: n.label, ipv4: n.ipv4 }))))

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

      const removedNodes = previousInstances.filter(
        (prev) => prev.instanceId && !nodesToProcess.some((node) => node.instanceId === prev.instanceId),
      )
      if (removedNodes.length > 0) {
        await Promise.all(removedNodes.map((node) => removeSubscriptionForNode(node.instanceId)))
      }

      const activeSubscriptionIds = new Set(
        enriched
          .filter((node) => node.instanceId)
          .map((node) => subscriptionId(node.instanceId)),
      )
      const staleSubscriptions = deps.subscribesStore.subscribes.filter(
        (sub: any) => sub.id.startsWith('cloud-') && !activeSubscriptionIds.has(sub.id),
      )
      if (staleSubscriptions.length > 0) {
        await Promise.all(staleSubscriptions.map((sub: any) => removeSubscriptionForNode(sub.id)))
      }

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
    if (!config.apiKey || config.apiKey.trim() === '') {
      stopAutoRefresh()
      return
    }
    if (autoRefreshTimer !== null) {
      return
    }

    const runRefresh = () => {
      if (!config.apiKey || config.apiKey.trim() === '') {
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
      const res = await retryWithBackoff(
        () => CreateCloudInstance(JSON.stringify(options)),
        'CreateCloudInstance',
        { maxAttempts: 3, baseDelay: 2000 }
      )
      ensureFlag(res.flag, res.data)
      const rawNode = parseJSON<Record<string, any>>(res.data, {} as CloudNode)
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
      const res = await CreateCloudInstance(JSON.stringify(options))
      ensureFlag(res.flag, res.data)
      const rawNode = parseJSON<Record<string, any>>(res.data, {})
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
      const res = await CreateMultipleCloudInstances(JSON.stringify(configs))
      ensureFlag(res.flag, res.data)
      const results = parseJSON<import('@/types/cloud').MultiDeployResult[]>(res.data, [])
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
      const res = await DestroyCloudInstance(instanceId)
      ensureFlag(res.flag, res.data)
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
    verifyNodeConnectivity,
  }
}
