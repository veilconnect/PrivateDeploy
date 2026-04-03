import { defineStore } from 'pinia'
import { reactive, ref, shallowRef, computed, watch } from 'vue'

import { logError, logInfo } from '@/utils/logger'

import { useAppSettingsStore } from './appSettings'
import {
  type CloudNodeStatus,
  type ProtocolHealthMap,
} from './cloud/constants'
import { hasUsableAddress } from './cloud/helpers'
import { createCloudHistory } from './cloud/history'
import { createInstanceSync } from './cloud/instanceSync'
import { createCloudLoadBalance } from './cloud/loadBalance'
import { createManualImport } from './cloud/manualImport'
import { createProviderConfig } from './cloud/providerConfig'
import { createSubscriptionApply } from './cloud/subscriptionApply'
import { useKernelApiStore } from './kernelApi'
import { useProfilesStore } from './profiles'
import { useSubscribesStore } from './subscribes'

import type { ManagedCloudNode, NodeHistoryMap } from './cloud/types'
import type { CloudProvider, CloudConfig, CloudRegion, CloudPlan } from '@/types/cloud'

// Re-export types for backward compatibility
export type { ManagedCloudNode } from './cloud/types'
export type { ManualNodeSkipEntry, NodeHistoryMap } from './cloud/types'

export const useCloudStore = defineStore('cloud', () => {
  // Multi-cloud provider management
  const availableProviders = ref<Array<{ name: string; displayName: string }>>([])
  const currentProvider = ref<CloudProvider>('vultr')

  const config = reactive<CloudConfig>({
    apiKey: '',
    defaultPlan: '',
    defaultRegion: '',
    extra: {},
  })
  const configLoaded = ref(false)
  const savingConfig = ref(false)

  // Use shallowRef for large arrays to reduce reactivity overhead
  // These arrays contain many items but we only replace them entirely, never mutate items
  const regions = shallowRef<CloudRegion[]>([])
  const plans = shallowRef<CloudPlan[]>([])
  const availability = reactive<Record<string, string[]>>({})
  const instances = shallowRef<ManagedCloudNode[]>([])
  const hasReadyInstances = computed(() => instances.value.some((node) => hasUsableAddress(node)))

  const loadingRegions = ref(false)
  const loadingPlans = ref(false)
  const loadingInstances = ref(false)
  const instancesUpdatedAt = ref<number | null>(null)

  // Cache management - timestamps for cache expiration
  const regionsUpdatedAt = ref<number | null>(null)
  const plansUpdatedAt = ref<number | null>(null)
  const latencyUpdatedAt = ref<number | null>(null)
  const latencyTestResults = ref<Record<string, number>>({}) // region code -> latency in ms
  const creatingInstance = ref(false)
  const destroyingInstance = ref<string>('')
  const manualNodesLoaded = ref(false)
  const manualNodes = shallowRef<ManagedCloudNode[]>([])
  const protocolHealthLoaded = ref(false)
  const protocolHealth = shallowRef<ProtocolHealthMap>({})
  const nodeHistoryLoaded = ref(false)
  const nodeHistory = shallowRef<NodeHistoryMap>({})

  const subscribesStore = useSubscribesStore()
  const profilesStore = useProfilesStore()
  const appSettingsStore = useAppSettingsStore()
  const kernelApiStore = useKernelApiStore()
  let kernelReloadTask: Promise<void> | null = null
  let lastKernelReloadAt = 0

  const reloadKernel = async (
    reason: string,
    options?: {
      allowStartWhenStopped?: boolean
    },
  ) => {
    const allowStartWhenStopped = options?.allowStartWhenStopped ?? true
    if (kernelReloadTask) {
      logInfo('[CloudStore] Kernel reload joined:', reason)
      return kernelReloadTask
    }

    const now = Date.now()
    if (now - lastKernelReloadAt < 3_000) {
      logInfo('[CloudStore] Kernel reload throttled:', reason)
      return
    }

    const task = (async () => {
      const profileId = appSettingsStore.app.kernel.profile
      const hasValidProfile = profileId && profilesStore.getProfileById(profileId)

      if (kernelApiStore.running) {
        await kernelApiStore.restartCore()
        logInfo('[CloudStore] Kernel restarted:', reason)
        return
      }

      if (!allowStartWhenStopped) {
        return
      }

      if (!appSettingsStore.app.autoStartKernel) {
        logInfo('[CloudStore] Skipping auto-start: autoStartKernel is disabled')
        return
      }

      if (!hasValidProfile) {
        logInfo('[CloudStore] Skipping auto-start: no valid profile configured')
        return
      }

      await kernelApiStore.startCore(undefined, { promptSystemProxy: false })
      logInfo('[CloudStore] Kernel started:', reason)
    })()

    kernelReloadTask = task
    try {
      await task
      lastKernelReloadAt = Date.now()
    } finally {
      if (kernelReloadTask === task) {
        kernelReloadTask = null
      }
    }
  }

  const markNodeStatus = (instanceId: string, status: CloudNodeStatus) => {
    const node = instances.value.find((item) => item.instanceId === instanceId)
    if (node) {
      node.statusText = status
      return
    }
    const manual = manualNodes.value.find((item) => item.instanceId === instanceId)
    if (manual) {
      manual.statusText = status
    }
  }

  // Multi-deploy progress tracking
  const multiDeployProgress = ref<Map<string, import('@/types/cloud').DeployProgress>>(new Map())

  // ─── Subscription & Profile Apply ────────────────────────────────────────────

  const subscriptionApply = createSubscriptionApply({
    protocolHealth,
    protocolHealthLoaded,
    subscribesStore,
    profilesStore,
    appSettingsStore,
    kernelApiStore,
    reloadKernel,
  })

  const {
    ensureSubscriptionForNode,
    removeSubscriptionForNode,
    migrateManagedNodeIdentity,
    applyNodeToProfile,
    updateProtocolHealthFromConnectivity,
  } = subscriptionApply

  // ─── Manual Node Import ──────────────────────────────────────────────────────

  const manualImport = createManualImport({
    manualNodes,
    manualNodesLoaded,
    instances,
    instancesUpdatedAt,
    markNodeStatus,
    ensureSubscriptionForNode,
  })

  const {
    loadManualNodes,
    syncManualNodesIntoInstances,
    addManualNode,
    addManualNodes,
    updateManualNode,
  } = manualImport

  // Wrap applyAllNodesToProfile to provide the closure dependencies
  const applyAllNodesToProfile = async () => {
    return subscriptionApply.applyAllNodesToProfile(
      instances,
      loadManualNodes,
      syncManualNodesIntoInstances,
      markNodeStatus,
    )
  }

  // ─── Node History ───────────────────────────────────────────────────────────

  const historyModule = createCloudHistory({
    nodeHistory,
    nodeHistoryLoaded,
  })

  const {
    loadNodeHistory,
    clearNodeHistory,
    migrateNodeHistory,
    recordConnectivitySample,
    recordSpeedSample,
  } = historyModule

  // ─── Instance Sync ───────────────────────────────────────────────────────────

  const instanceSyncModule = createInstanceSync({
    config,
    currentProvider,
    instances,
    instancesUpdatedAt,
    loadingInstances,
    creatingInstance,
    destroyingInstance,
    manualNodes,
    latencyTestResults,
    latencyUpdatedAt,
    multiDeployProgress,
    appSettingsStore,
    profilesStore,
    kernelApiStore,
    subscribesStore,
    ensureSubscriptionForNode,
    removeSubscriptionForNode,
    migrateManagedNodeIdentity,
    applyNodeToProfile,
    applyAllNodesToProfile,
    loadNodeHistory,
    migrateNodeHistory,
    recordConnectivitySample,
    recordSpeedSample,
    loadManualNodes,
    syncManualNodesIntoInstances,
    saveManualNodes: manualImport.saveManualNodes,
    ensureRegionAvailability: (...args: [string, boolean?]) => providerConfigModule.ensureRegionAvailability(...args),
    updateProtocolHealthFromConnectivity,
    reloadKernel,
    markNodeStatus,
  })

  const {
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
  } = instanceSyncModule

  // ─── Provider Config ─────────────────────────────────────────────────────────

  const providerConfigModule = createProviderConfig({
    availableProviders,
    currentProvider,
    config,
    configLoaded,
    savingConfig,
    regions,
    plans,
    availability,
    loadingRegions,
    loadingPlans,
    regionsUpdatedAt,
    plansUpdatedAt,
    instances,
    instancesUpdatedAt,
    startAutoRefresh,
    stopAutoRefresh,
    refreshInstances,
  })

  const {
    loadConfig,
    saveConfig,
    fetchRegions,
    fetchPlans,
    ensureRegionAvailability,
    loadProviders,
    switchProvider,
    getCurrentProvider,
    isRegionsCacheValid,
    isPlansCacheValid,
  } = providerConfigModule

  // ─── Auto-start kernel watcher ───────────────────────────────────────────────

  let autoStartKernelLock = false
  watch(
    () => hasReadyInstances.value,
    async (ready) => {
      if (!ready || autoStartKernelLock) {
        return
      }
      if (kernelApiStore.running) {
        return
      }
      autoStartKernelLock = true
      try {
        await applyAllNodesToProfile().catch((error) => {
          logError('[CloudStore] Auto-apply during auto-start failed:', error)
          return []
        })
      } catch (error) {
        logError('[CloudStore] Auto-start kernel failed:', error)
      } finally {
        autoStartKernelLock = false
      }
    },
    { immediate: true },
  )

  // ─── Load Balance ──────────────────────────────────────────────────────────

  const {
    loadBalanceEnabled,
    loadBalanceListenPort,
    startLoadBalance,
    stopLoadBalance,
  } = createCloudLoadBalance({
    kernelApi: kernelApiStore,
  })

  void loadNodeHistory()

  return {
    // Multi-cloud
    availableProviders,
    currentProvider,
    loadProviders,
    switchProvider,
    getCurrentProvider,
    // Config
    config,
    configLoaded,
    savingConfig,
    loadConfig,
    saveConfig,
    // Data
    regions,
    plans,
    instances,
    nodeHistory,
    availability,
    hasReadyInstances,
    // Loading states
    loadingRegions,
    loadingPlans,
    loadingInstances,
    creatingInstance,
    destroyingInstance,
    // Methods
    markNodeStatus,
    fetchRegions,
    fetchPlans,
    refreshInstances,
    ensureRegionAvailability,
    isRegionsCacheValid,
    isPlansCacheValid,
    isInstancesCacheValid,
    isLatencyCacheValid,
    latencyTestResults,
    latencyUpdatedAt,
    createInstance,
    createSSHInstance,
    createMultipleInstances,
    multiDeployProgress,
    destroyInstance,
    rotateIP,
    applyNodeToProfile,
    applyAllNodesToProfile,
    startAutoRefresh,
    stopAutoRefresh,
    clearAllTimers,
    testNodeConnectivity,
    testAllNodesConnectivity,
    testNodeSpeedTest,
    testAllNodesSpeed,
    verifyNodeConnectivity,
    addManualNode,
    addManualNodes,
    updateManualNode,
    loadManualNodes,
    loadNodeHistory,
    clearNodeHistory,
    instancesUpdatedAt,
    // Load balance
    loadBalanceEnabled,
    loadBalanceListenPort,
    startLoadBalance,
    stopLoadBalance,
  }
})
