import { defineStore } from 'pinia'
import { reactive, ref, shallowRef, computed, watch } from 'vue'

import {
  GetCloudConfig,
  SaveCloudConfig,
  ListCloudProviders,
  GetCloudProvider,
  SetCloudProvider,
  ListCloudInstances,
  CreateCloudInstance,
  DestroyCloudInstance,
  ListCloudRegions,
  ListCloudPlans,
  ListCloudAvailability,
  ReadFile,
  WriteFile,
  RemoveFile,
  TestConnectivity,
} from '@/bridge'
import { DefaultSubscribeScript } from '@/constant/app'
import { DefaultExcludeProtocols } from '@/constant/kernel'
import * as ProfileDefaults from '@/constant/profile'
import { RequestMethod } from '@/enums/app'
import { Outbound } from '@/enums/kernel'
import { sampleID, deepClone, ignoredError } from '@/utils'
import { logError, logInfo } from '@/utils/logger'
import { notifications } from '@/utils/notification'
import { retryWithBackoff } from '@/utils/errorRecovery'
import { isOnline, saveToOfflineCache, loadFromOfflineCache, initOfflineMode } from '@/utils/offline'

import { useAppSettingsStore } from './appSettings'
import { useKernelApiStore } from './kernelApi'
import { useProfilesStore } from './profiles'
import { useSubscribesStore } from './subscribes'

import type { Subscription } from '@/types/app'
import type { CloudProvider, CloudConfig, CloudNode, CloudPlan, CloudRegion, ConnectivityStatus } from '@/types/cloud'


type CloudNodeStatus = 'unknown' | 'pending' | 'applying' | 'connected' | 'error'
export type ManagedCloudNode = CloudNode & {
  statusText?: CloudNodeStatus
  connectivityStatus?: ConnectivityStatus
  connectivityTesting?: boolean
}
const parseJSON = <T>(data: string | undefined | null, fallback: T): T => {
  if (!data) return fallback
  try {
    return JSON.parse(data) as T
  } catch (error) {
    logError('Failed to parse provider response', error)
    return fallback
  }
}

// Generate subscription ID from instance ID
// For DigitalOcean, instance IDs already have "cloud-do-" prefix, so use as-is
// For Vultr (legacy), instance IDs are UUIDs without prefix, so add "cloud-" prefix
const subscriptionId = (instanceId: string) => {
  // If ID already has a provider prefix (e.g., "cloud-do-"), use it directly
  if (instanceId.startsWith('cloud-')) {
    return instanceId
  }
  // Otherwise, add "cloud-" prefix for backward compatibility with Vultr
  return `cloud-${instanceId}`
}
const subscriptionPath = (instanceId: string) => `data/subscribes/${subscriptionId(instanceId)}.json`

const manualNodesPath = 'data/cloud/manual-nodes.json'

type ManualNodeInput = {
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
  vlessPort?: number
  vlessUUID?: string
  vlessPublicKey?: string
  vlessShortId?: string
  trojanPort?: number
  trojanPassword?: string
  createdAt?: string
}

type ManualNodeConflictType = 'label' | 'ipv4' | 'ipv6'
type ManualNodeConflict = {
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

class ManualNodeError extends Error {
  code: string
  meta?: Record<string, any>

  constructor(code: string, meta?: Record<string, any>) {
    super(code)
    this.code = code
    this.meta = meta
    this.name = 'ManualNodeError'
  }
}

const normalizeCloudNode = (rawNode: Record<string, any>, providerFallback: CloudProvider): ManagedCloudNode => {
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

const providerStatusToNodeStatus = (status?: string): CloudNodeStatus => {
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
  const CACHE_TTL = {
    regions: 30 * 60 * 1000,      // 30 minutes - regions rarely change
    plans: 30 * 60 * 1000,        // 30 minutes - plans rarely change
    instances: 2 * 60 * 1000,     // 2 minutes - instances change more frequently
    instancesBackground: 5 * 60 * 1000,  // 5 minutes for background refresh
    latency: 24 * 60 * 60 * 1000, // 24 hours - latency tests are expensive
  }
  const creatingInstance = ref(false)
  const destroyingInstance = ref<string>('')
  const manualNodesLoaded = ref(false)
  const manualNodes = shallowRef<ManagedCloudNode[]>([])
  let autoRefreshTimer: ReturnType<typeof setInterval> | null = null
  const autoApplyTimers = new Map<string, ReturnType<typeof setInterval>>()

  const subscribesStore = useSubscribesStore()
  const profilesStore = useProfilesStore()
  const appSettingsStore = useAppSettingsStore()
  const kernelApiStore = useKernelApiStore()

  const ensureFlag = (flag: boolean, data: string) => {
    if (!flag) throw new Error(data)
  }

  /**
   * Check if cache is still valid
   */
  const isCacheValid = (timestamp: number | null, ttl: number): boolean => {
    if (!timestamp) return false
    return Date.now() - timestamp < ttl
  }

  /**
   * Check if regions cache is valid
   */
  const isRegionsCacheValid = () => isCacheValid(regionsUpdatedAt.value, CACHE_TTL.regions)

  /**
   * Check if plans cache is valid
   */
  const isPlansCacheValid = () => isCacheValid(plansUpdatedAt.value, CACHE_TTL.plans)

  /**
   * Check if instances cache is valid
   */
  const isInstancesCacheValid = () => isCacheValid(instancesUpdatedAt.value, CACHE_TTL.instances)

  /**
   * Check if latency test cache is valid
   */
  const isLatencyCacheValid = () => isCacheValid(latencyUpdatedAt.value, CACHE_TTL.latency)

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

  const ensureRegionAvailability = async (region: string, force = false) => {
    if (!region) return [] as string[]
    if (!force && availability[region]) {
      return availability[region]
    }

    if (!config.apiKey || config.apiKey.trim() === '') {
      availability[region] = availability[region] || []
      return availability[region]
    }

    try {
      const res = await ListCloudAvailability(region)
      ensureFlag(res.flag, res.data)
      availability[region] = parseJSON<string[]>(res.data, [])
    } catch (error) {
      logError('[CloudStore] Failed to load availability:', error)
      availability[region] = availability[region] || []
      throw error
    }

    return availability[region]
  }

  const ensureSubscriptionForNode = async (node: CloudNode) => {
    // Check if we have at least one IP address
  if (!hasUsableAddress(node)) {
    await removeSubscriptionForNode(node.instanceId)
    return
  }

    const id = subscriptionId(node.instanceId)
    const path = subscriptionPath(node.instanceId)

    // Build outbounds array with all available protocols
    // For each protocol, if both IPv4 and IPv6 are available, create separate nodes
    const outbounds: any[] = []

    // Determine which IP versions are available for proxy configuration
    // Filter out private/internal IPs (100.64.0.0/10 CGNAT, 10.0.0.0/8, 192.168.0.0/16, 172.16.0.0/12)
  const hasIPv4 = !!node.ipv4 && node.ipv4 !== '' && isPublicIPv4Address(node.ipv4)
  const hasIPv6 = !!node.ipv6 && node.ipv6 !== ''
    const ipVersions: Array<{ ip: string; suffix: string }> = []

    // Generate configurations for all available public IPs
    // sing-box will automatically try available connections
    if (hasIPv4 && node.ipv4) {
      ipVersions.push({ ip: node.ipv4, suffix: '-v4' })
    }
    if (hasIPv6 && node.ipv6) {
      ipVersions.push({ ip: node.ipv6, suffix: '-v6' })
    }

    // Skip nodes with only internal/private IPs - they cannot be used for external connections
  if (ipVersions.length === 0) {
    console.log(`[CloudStore] Node ${node.label} has no usable public IP addresses, skipping subscription generation`)
    await removeSubscriptionForNode(node.instanceId)
    return
  }

    // 1. Shadowsocks (always available - legacy compatibility)
    if (node.ssPort && node.ssPassword) {
      ipVersions.forEach(({ ip, suffix }) => {
        outbounds.push({
          type: 'shadowsocks',
          tag: `${node.label}-ss${suffix}`,
          server: ip,
          server_port: node.ssPort,
          method: 'aes-256-gcm',
          password: node.ssPassword,
        })
      })
    }

    // 2. Hysteria2 (UDP-based, better for congested networks)
    if (node.hysteriaPort && node.hysteriaPassword) {
      ipVersions.forEach(({ ip, suffix }) => {
        outbounds.push({
          type: 'hysteria2',
          tag: `${node.label}-hysteria2${suffix}`,
          server: ip,
          server_port: node.hysteriaPort,
          up_mbps: 100,
          down_mbps: 100,
          password: node.hysteriaPassword,
          tls: {
            enabled: true,
            insecure: true,
            server_name: 'www.bing.com',
          },
        })
      })
    }

    // 3. VLESS-Reality (best anti-censorship)
    if (node.vlessPort && node.vlessUUID && node.vlessPublicKey && node.vlessShortId) {
      // Convert public_key to URL-safe base64 format (sing-box Reality requirement)
      // Standard base64 uses +/ while URL-safe uses -_
      const publicKeyUrlSafe = node.vlessPublicKey.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')

      ipVersions.forEach(({ ip, suffix }) => {
        outbounds.push({
          type: 'vless',
          tag: `${node.label}-vless${suffix}`,
          server: ip,
          server_port: node.vlessPort,
          uuid: node.vlessUUID,
          flow: 'xtls-rprx-vision',
          tls: {
            enabled: true,
            server_name: 'www.microsoft.com',
            utls: {
              enabled: true,
              fingerprint: 'chrome',
            },
            reality: {
              enabled: true,
              public_key: publicKeyUrlSafe,
              short_id: node.vlessShortId,
            },
          },
        })
      })
    }

    // 4. Trojan (good balance of security and performance)
    if (node.trojanPort && node.trojanPassword) {
      ipVersions.forEach(({ ip, suffix }) => {
        outbounds.push({
          type: 'trojan',
          tag: `${node.label}-trojan${suffix}`,
          server: ip,
          server_port: node.trojanPort,
          password: node.trojanPassword,
          tls: {
            enabled: true,
            insecure: true,
            server_name: 'www.microsoft.com',
          },
        })
      })
    }

    // Fallback: if no multi-protocol data, use legacy format
    // Check both node.port/password and node.ssPort/ssPassword for compatibility
    if (outbounds.length === 0) {
      const port = node.port || node.ssPort
      const password = node.password || node.ssPassword

      if (port && password) {
        ipVersions.forEach(({ ip, suffix }) => {
          outbounds.push({
            type: 'shadowsocks',
            tag: `${node.label}${suffix}`,
            server: ip,
            server_port: port,
            method: 'aes-256-gcm',
            password: password,
          })
        })
      }
    }

    // Don't add selector/urltest to subscription file
    // They will be generated by the profile system
    // Only export the actual protocol nodes
    const payload = {
      outbounds,
    }

    const newContent = JSON.stringify(payload, null, 2)
    const existing = subscribesStore.getSubscribeById(id)

    // Only write file if this is a new subscription or updateTime is more than 5 minutes old
    // This avoids unnecessary file I/O on every refresh
    const shouldWrite = !existing || (Date.now() - existing.updateTime > 5 * 60 * 1000)

    if (shouldWrite) {
      await WriteFile(path, newContent)
    }

    const subscription: Subscription = existing
      ? { ...existing }
      : {
          id,
          name: node.label,
          upload: 0,
          download: 0,
          total: 0,
          expire: 0,
          updateTime: Date.now(),
          type: 'Manual',
          url: '',
          website: '',
          path,
          include: '',
          exclude: '',
          includeProtocol: '',
          excludeProtocol: DefaultExcludeProtocols,
          proxyPrefix: '',
          disabled: false,
          inSecure: false,
          requestMethod: RequestMethod.Get,
          header: {
            request: {},
            response: {},
          },
          proxies: [],
          script: DefaultSubscribeScript,
        }

    subscription.name = node.label
    subscription.type = 'Manual'
    subscription.path = path
    subscription.updateTime = Date.now()
    subscription.script ||= DefaultSubscribeScript
    subscription.requestMethod ||= RequestMethod.Get
    subscription.excludeProtocol ||= DefaultExcludeProtocols
    subscription.include = subscription.include || ''
    subscription.exclude = subscription.exclude || ''
    subscription.includeProtocol = subscription.includeProtocol || ''
    subscription.proxyPrefix = subscription.proxyPrefix || ''
    subscription.header = subscription.header || { request: {}, response: {} }
    subscription.header.request = subscription.header.request || {}
    subscription.header.response = subscription.header.response || {}
    subscription.proxies = subscription.proxies || []

    if (existing) {
      await subscribesStore.editSubscribe(id, subscription)
    } else {
      await subscribesStore.addSubscribe(subscription)
    }
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

  const saveManualNodes = async () => {
    await WriteFile(manualNodesPath, JSON.stringify(manualNodes.value, null, 2))
  }

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

  const sanitizePort = (value: unknown): number | undefined => {
    const num = Number(value)
    if (!Number.isFinite(num)) return undefined
    const port = Math.trunc(num)
    if (port <= 0 || port > 65535) return undefined
    return port
  }

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
      vlessPort: sanitizePort(input.vlessPort),
      vlessUUID: input.vlessUUID?.trim() || undefined,
      vlessPublicKey: input.vlessPublicKey?.trim() || undefined,
      vlessShortId: input.vlessShortId?.trim() || undefined,
      trojanPort: sanitizePort(input.trojanPort),
      trojanPassword: input.trojanPassword?.trim() || undefined,
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

  const removeSubscriptionForNode = async (instanceId: string) => {
    const id = subscriptionId(instanceId)
    const path = subscriptionPath(instanceId)
    const existing = subscribesStore.getSubscribeById(id)
    if (existing) {
      await subscribesStore.deleteSubscribe(id)
    }
    await RemoveFile(path).catch(() => undefined)

    // Optimistic UI update: immediately remove from proxy groups for instant feedback
    // Remove running check - update UI regardless of kernel state for instant feedback
    kernelApiStore.removeProxyFromGroups(id)
    logInfo('[CloudStore] Optimistically removed proxy from groups:', id)

    // Remove references from all profiles that used this subscription
    const toPrune: Array<Promise<void>> = []
    for (const profile of profilesStore.profiles) {
      if (!profile) continue
      let changed = false
      const updated = deepClone(profile)

      const pruneOutbound = (outbound: IOutbound) => {
        if (!outbound) return
        if (Array.isArray(outbound.outbounds)) {
          const before = outbound.outbounds.length
          outbound.outbounds = outbound.outbounds
            .map((item: any) => (item && typeof item === 'object' ? { ...item } : item))
            .filter((item: any) => item?.id !== id)
          if (before !== outbound.outbounds.length) {
            changed = true
          }
        }
      }

      updated.outbounds.forEach(pruneOutbound)

      // Remove direct subscription outbounds (non-selector/urltest)
      const beforeLength = updated.outbounds.length
      updated.outbounds = updated.outbounds.filter((outbound: IOutbound) => outbound.id !== id)
      if (beforeLength !== updated.outbounds.length) {
        changed = true
      }

      if (changed) {
        toPrune.push(profilesStore.editProfile(profile.id, updated))
      }
    }

    if (toPrune.length > 0) {
      await Promise.all(toPrune)
      if (kernelApiStore.running) {
        try {
          await kernelApiStore.restartCore()
          logInfo('[CloudStore] Core restarted after removing subscription:', id)
          // Refresh proxy groups to update the UI
          await kernelApiStore.refreshProviderProxies().catch((error) =>
            logError('[CloudStore] Failed to refresh proxies after removing subscription:', error),
          )
        } catch (error) {
          logError('[CloudStore] Failed to restart core after pruning subscription:', error)
        }
      }
    }
  }

  const loadConfig = async () => {
    const res = await GetCloudConfig()
    ensureFlag(res.flag, res.data)
    const loadedConfig = parseJSON<CloudConfig>(res.data, {} as CloudConfig)
    Object.assign(config, loadedConfig)
    config.provider = loadedConfig.provider ?? currentProvider.value
    config.extra = loadedConfig.extra ?? {}
    logInfo('[CloudStore] Loaded config, apiKey length:', config.apiKey?.length || 0)
    configLoaded.value = true
    if (config.apiKey && config.apiKey.trim() !== '') {
      startAutoRefresh(true)
    } else {
      stopAutoRefresh()
    }
  }

  const saveConfig = async () => {
    savingConfig.value = true
    try {
      const payload = deepClone(config) as CloudConfig
      payload.provider = currentProvider.value
      payload.extra = payload.extra ?? {}
      const res = await retryWithBackoff(
        () => SaveCloudConfig(JSON.stringify(payload)),
        'SaveCloudConfig',
        { maxAttempts: 3, baseDelay: 1000 }
      )
      ensureFlag(res.flag, res.data)
      if (payload.apiKey && payload.apiKey.trim() !== '') {
        startAutoRefresh(true)
      } else {
        stopAutoRefresh()
      }

      // Notify config saved successfully
      notifications.configSaved()
    } catch (error) {
      // Notify config save failed
      notifications.error('Configuration Save Failed', error instanceof Error ? error.message : String(error))
      throw error
    } finally {
      savingConfig.value = false
    }
  }

  /**
   * Fetch regions with cache support
   * @param force - Force refresh ignoring cache
   */
  const fetchRegions = async (force = false) => {
    // Return cached data if valid and not forcing refresh
    if (!force && isRegionsCacheValid() && regions.value.length > 0) {
      logInfo('[CloudStore] Using cached regions data')
      return
    }

    // If offline, try to load from offline cache
    if (!isOnline.value) {
      const cached = loadFromOfflineCache<CloudRegion[]>('regions')
      if (cached) {
        regions.value = cached
        regionsUpdatedAt.value = Date.now()
        logInfo('[CloudStore] Loaded regions from offline cache')
        return
      }
    }

    loadingRegions.value = true
    try {
      const res = await retryWithBackoff(
        () => ListCloudRegions(),
        'ListCloudRegions',
        { maxAttempts: 2, baseDelay: 1000 }
      )
      ensureFlag(res.flag, res.data)
      regions.value = parseJSON<CloudRegion[]>(res.data, [])
      regionsUpdatedAt.value = Date.now()

      // Save to offline cache
      saveToOfflineCache('regions', regions.value)

      logInfo('[CloudStore] Regions fetched and cached')
    } catch (error) {
      // If fetch fails, try offline cache as fallback
      const cached = loadFromOfflineCache<CloudRegion[]>('regions')
      if (cached) {
        regions.value = cached
        regionsUpdatedAt.value = Date.now()
        logInfo('[CloudStore] Failed to fetch regions, using offline cache')
      } else {
        throw error
      }
    } finally {
      loadingRegions.value = false
    }
  }

  /**
   * Fetch plans with cache support
   * @param force - Force refresh ignoring cache
   */
  const fetchPlans = async (force = false) => {
    // Return cached data if valid and not forcing refresh
    if (!force && isPlansCacheValid() && plans.value.length > 0) {
      logInfo('[CloudStore] Using cached plans data')
      return
    }

    // If offline, try to load from offline cache
    if (!isOnline.value) {
      const cached = loadFromOfflineCache<CloudPlan[]>('plans')
      if (cached) {
        plans.value = cached
        plansUpdatedAt.value = Date.now()
        logInfo('[CloudStore] Loaded plans from offline cache')
        return
      }
    }

    loadingPlans.value = true
    try {
      const res = await retryWithBackoff(
        () => ListCloudPlans(),
        'ListCloudPlans',
        { maxAttempts: 2, baseDelay: 1000 }
      )
      ensureFlag(res.flag, res.data)
      plans.value = parseJSON<CloudPlan[]>(res.data, [])
      plansUpdatedAt.value = Date.now()

      // Save to offline cache
      saveToOfflineCache('plans', plans.value)

      logInfo('[CloudStore] Plans fetched and cached')
    } catch (error) {
      // If fetch fails, try offline cache as fallback
      const cached = loadFromOfflineCache<CloudPlan[]>('plans')
      if (cached) {
        plans.value = cached
        plansUpdatedAt.value = Date.now()
        logInfo('[CloudStore] Failed to fetch plans, using offline cache')
      } else {
        throw error
      }
    } finally {
      loadingPlans.value = false
    }
  }

  /**
   * Refresh instances with cache support
   * @param silent - Don't show loading indicator
   * @param force - Force refresh ignoring cache
   */
  const refreshInstances = async (silent = false, force = false) => {
    if (!config.apiKey || config.apiKey.trim() === '') {
      instances.value = []
      instancesUpdatedAt.value = Date.now()
      return
    }

    // Use cached data if valid and not forcing refresh
    if (!force && isInstancesCacheValid() && instances.value.length > 0) {
      logInfo('[CloudStore] Using cached instances data')
      return
    }

    // If offline, try to load from offline cache
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
      console.log('[CloudStore] Raw nodes from backend:', rawNodes.length, rawNodes)
      const normalizedNodes = rawNodes
        .map((node) => normalizeCloudNode(node, currentProvider.value))
      console.log('[CloudStore] Normalized nodes:', normalizedNodes.length, normalizedNodes)
      const filteredNodes = normalizedNodes.filter((node) => node.instanceId)
      console.log('[CloudStore] After filtering by instanceId:', filteredNodes.length, filteredNodes)
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

      // Save to offline cache
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

      if (enriched.some((node) => hasUsableAddress(node))) {
        await applyAllNodesToProfile().catch((error) => {
          logError('[CloudStore] Failed to auto-apply nodes after refresh:', error)
        })
      }

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

      let restartedAfterAutoApply = false
      for (const node of nodesToAutoApply) {
        try {
          logInfo('[CloudStore] Auto-applying newly ready node:', node.label)
          await applyNodeToProfile(node)

          // Optimistic UI update: immediately add all proxy nodes to groups for instant feedback
          // Remove running check - update UI regardless of kernel state for instant feedback
          kernelApiStore.addCloudNodeToGroups(node)
          logInfo('[CloudStore] Optimistically added cloud node proxies to groups:', node.label)

          node.statusText = 'connected'
          instances.value = instances.value.map((n) =>
            n.instanceId === node.instanceId ? node : n,
          )
          instancesUpdatedAt.value = Date.now()
          restartedAfterAutoApply = true
          logInfo('[CloudStore] Successfully auto-applied node:', node.label)
        } catch (error) {
          logError('[CloudStore] Auto-apply failed for node:', node.label, error)
          // If auto-apply fails, reset status to 'pending' so user can manually apply
          node.statusText = 'pending'
          instances.value = instances.value.map((n) =>
            n.instanceId === node.instanceId ? node : n,
          )
          instancesUpdatedAt.value = Date.now()
        }
      }

      if (restartedAfterAutoApply) {
        // Verify profile exists before attempting to start/restart kernel
        const profileId = appSettingsStore.app.kernel.profile
        const hasValidProfile = profileId && profilesStore.getProfileById(profileId)

        if (!hasValidProfile) {
          logError('[CloudStore] Cannot start kernel after auto-apply: no valid profile found')
        } else {
          try {
            if (kernelApiStore.running) {
              await kernelApiStore.restartCore()
              logInfo('[CloudStore] Kernel restarted after auto-applying nodes')
            } else {
              await kernelApiStore.startCore()
              logInfo('[CloudStore] Kernel started after auto-applying nodes')
            }
            await kernelApiStore.refreshProviderProxies().catch((error) =>
              logError('[CloudStore] Failed to refresh provider proxies after auto-apply:', error),
            )
          } catch (error) {
            logError('[CloudStore] Failed to restart kernel after auto-applying nodes:', error)
            // Even if kernel fails to start, nodes are already applied to profile
            // User can manually start kernel from Overview page
          }
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
      const staleSubscriptions = subscribesStore.subscribes.filter(
        (sub) => sub.id.startsWith('cloud-') && !activeSubscriptionIds.has(sub.id),
      )
      if (staleSubscriptions.length > 0) {
        await Promise.all(staleSubscriptions.map((sub) => removeSubscriptionForNode(sub.id)))
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
          if (kernelApiStore.running) {
            await kernelApiStore.restartCore()
          } else {
            await kernelApiStore.startCore()
          }
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

      if (!bulkApplied.length && kernelApiStore.running) {
        // Refresh proxy groups when no new nodes were applied but state may have changed
        await kernelApiStore.refreshProviderProxies().catch((error) =>
          logError('[CloudStore] Failed to refresh provider proxies:', error),
        )
      }
    } catch (error) {
      logError('[CloudStore] refreshInstances error:', error)

      // If fetch fails, try offline cache as fallback
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
      if (!silent) {
        loadingInstances.value = false
      }
    }
  }

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

  /**
   * 清理所有定时器，防止内存泄漏
   * 应该在组件卸载时调用
   */
  const clearAllTimers = () => {
    // 停止自动刷新定时器
    stopAutoRefresh()

    // 停止所有自动应用定时器
    const instanceIds = Array.from(autoApplyTimers.keys())
    instanceIds.forEach(id => stopAutoApplyTimer(id))

    logInfo('[CloudStore] Cleared all timers')
  }

  /**
   * Test connectivity to a specific node
   * Tests ICMP reachability and all configured protocol ports
   */
  const testNodeConnectivity = async (instanceId: string) => {
    // Find the node
    const node = instances.value.find((item) => item.instanceId === instanceId) ||
                 manualNodes.value.find((item) => item.instanceId === instanceId)

    if (!node) {
      logError('[CloudStore] Node not found for connectivity test:', instanceId)
      return
    }

    // Determine which IP to test (prefer IPv4 for regional reachability detection)
    const testIP = node.ipv4 || node.ipv6
    if (!testIP) {
      logError('[CloudStore] No IP address available for node:', instanceId)
      node.connectivityStatus = 'unknown'
      return
    }

    // Collect all configured ports for this node
    const ports: number[] = []
    if (node.ssPort) ports.push(node.ssPort)
    if (node.hysteriaPort) ports.push(node.hysteriaPort)
    if (node.vlessPort) ports.push(node.vlessPort)
    if (node.trojanPort) ports.push(node.trojanPort)

    // Mark as testing
    node.connectivityTesting = true
    node.connectivityStatus = 'testing'
    logInfo(`[CloudStore] Testing connectivity to ${testIP} ports:`, ports)

    try {
      const result = await retryWithBackoff(
        () => TestConnectivity(testIP, ports),
        'TestConnectivity',
        { maxAttempts: 2, baseDelay: 1000 }
      )
      logInfo('[CloudStore] Connectivity test result:', result)

      // Update connectivity status based on result
      node.connectivityStatus = result.status
      node.connectivityTesting = false

      // Notify based on connectivity result
      if (result.status === 'blocked') {
        notifications.connectivityBlocked(node.label)
      } else if (result.status === 'reachable') {
        notifications.connectivityRestored(node.label)
      }
    } catch (error) {
      logError('[CloudStore] Connectivity test failed:', error)
      node.connectivityStatus = 'unknown'
      node.connectivityTesting = false

      // Notify test failure
      notifications.error(
        'Connectivity Test Failed',
        `Failed to test connectivity for ${node.label}: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  }

  /**
   * Test connectivity for all nodes
   */
  const testAllNodesConnectivity = async () => {
    const allNodes = [...instances.value, ...manualNodes.value]
    const testPromises = allNodes.map(node => testNodeConnectivity(node.instanceId))
    await Promise.allSettled(testPromises)
    logInfo('[CloudStore] Completed connectivity tests for all nodes')
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

  /**
   * Start background auto-refresh with optimized interval
   * Uses cache to avoid unnecessary API calls
   */
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
      // Use cache-aware refresh (will skip if cache is valid)
      refreshInstances(true, false).catch((error) => {
        logError('[CloudStore] Auto refresh failed:', error)
      })
    }

    // Optimized: 5 minutes interval (cache handles freshness check)
    // Previously: 15 seconds (too aggressive)
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

        // If node doesn't have IP yet, wait for it with retry mechanism
        // Backend should have waited, but if it failed we retry here
        if (!cloudNode.ipv4 && !cloudNode.ipv6) {
          logInfo('[CloudStore] Node created without IP, will retry subscription creation after refresh')
          cloudNode.statusText = 'pending'
          instances.value = instances.value.map((n) =>
            n.instanceId === cloudNode.instanceId ? cloudNode : n
          )
          // Trigger immediate refresh to get IP address
          setTimeout(() => refreshInstances(true).catch(() => undefined), 5000)
          return node
        }

        await ensureSubscriptionForNode(cloudNode)

        // Auto-apply: Add newly created node to active profile and restart core
        let applySuccess = false
        try {
          await applyNodeToProfile(cloudNode)
          applySuccess = true
          logInfo('[CloudStore] Successfully applied new node to profile:', cloudNode.label)

          // Optimistic UI update: immediately add all proxy nodes to groups for instant feedback
          // Remove running check - update UI regardless of kernel state for instant feedback
          kernelApiStore.addCloudNodeToGroups(cloudNode)
          logInfo('[CloudStore] Optimistically added cloud node proxies to groups:', cloudNode.label)

          // Update status to 'connected' after successful apply
          cloudNode.statusText = 'connected'
          instances.value = instances.value.map((n) =>
            n.instanceId === cloudNode.instanceId ? cloudNode : n
          )
          instancesUpdatedAt.value = Date.now()

          // Notify deployment success
          notifications.deploymentComplete(cloudNode.label)
        } catch (error) {
          logError('[CloudStore] Auto-apply failed for new node:', cloudNode.label, error)
          // If auto-apply fails, reset status to 'pending' so user can manually apply
          cloudNode.statusText = 'pending'
          instances.value = instances.value.map((n) =>
            n.instanceId === cloudNode.instanceId ? cloudNode : n
          )
          instancesUpdatedAt.value = Date.now()

          // Notify deployment failure
          notifications.deploymentFailed(cloudNode.label, error instanceof Error ? error.message : String(error))
        }

        // If apply succeeded, try to start/restart kernel (separate from apply to avoid marking as failed if kernel fails)
        if (applySuccess) {
          const profileId = appSettingsStore.app.kernel.profile
          const hasValidProfile = profileId && profilesStore.getProfileById(profileId)

          if (hasValidProfile) {
            try {
              if (kernelApiStore.running) {
                await kernelApiStore.restartCore()
                logInfo('[CloudStore] Kernel restarted after deploying new node')
              } else {
                await kernelApiStore.startCore()
                logInfo('[CloudStore] Kernel started after deploying new node')
              }
              await kernelApiStore.refreshProviderProxies().catch((error) =>
                logError('[CloudStore] Failed to refresh proxies after deployment:', error),
              )

              // Auto-test connectivity after deployment
              logInfo('[CloudStore] Auto-testing connectivity for new node:', cloudNode.label)
              testNodeConnectivity(cloudNode.instanceId).catch((error) => {
                logError('[CloudStore] Auto connectivity test failed:', error)
              })
            } catch (error) {
              logError('[CloudStore] Kernel start/restart failed after deployment:', error)
              // Node is still successfully deployed, user can manually start kernel
            }
          } else {
            logInfo('[CloudStore] Skipping kernel start: no valid profile (this should not happen after applyNodeToProfile)')
          }
        }
      }
      return node
    } finally {
      creatingInstance.value = false
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

  /**
   * Rotate IP for a node by destroying and recreating it
   * Useful when a node's IP is blocked by regional reachability
   */
  const rotateIP = async (instanceId: string) => {
    // Find the node to get its configuration
    const node = instances.value.find((item) => item.instanceId === instanceId) ||
                 manualNodes.value.find((item) => item.instanceId === instanceId)

    if (!node) {
      throw new Error('Node not found for IP rotation')
    }

    // Manual nodes cannot rotate IP - they must be manually updated
    const isManual = manualNodes.value.some((n) => n.instanceId === instanceId)
    if (isManual) {
      throw new Error('Manual nodes cannot rotate IP automatically. Please edit the node to update IP address.')
    }

    // Save node configuration for recreation
    const nodeConfig = {
      label: node.label,
      region: node.region || '',
      plan: node.plan || '',
    }

    logInfo('[CloudStore] Rotating IP for node:', node.label, nodeConfig)

    // Notify IP rotation start
    notifications.info('IP Rotation Started', `Rotating IP for ${node.label}...`)

    try {
      // Destroy the existing instance
      await destroyInstance(instanceId)

      // Create a new instance with the same configuration
      logInfo('[CloudStore] Creating replacement instance with same configuration')
      const newNode = await createInstance(nodeConfig)

      logInfo('[CloudStore] IP rotation completed. New node:', newNode.instanceId)

      // Notify IP rotation success
      notifications.rotationComplete(node.label)

      return newNode
    } catch (error) {
      // Notify IP rotation failure
      notifications.rotationFailed(node.label, error instanceof Error ? error.message : String(error))
      throw error
    }
  }

  const applyAllNodesToProfile = async () => {
    await loadManualNodes()
    syncManualNodesIntoInstances()

    const existingProfileId = appSettingsStore.app.kernel.profile
    const existingProfile = existingProfileId
      ? profilesStore.getProfileById(existingProfileId)
      : undefined
    const existingSubscriptionIds = new Set<string>()
    if (existingProfile && Array.isArray(existingProfile.outbounds)) {
      for (const outbound of existingProfile.outbounds) {
        const outbounds = (outbound as any)?.outbounds
        if (Array.isArray(outbounds)) {
          for (const child of outbounds) {
            if (child?.id) {
              existingSubscriptionIds.add(child.id)
            }
          }
        }
      }
    }

    const candidates = instances.value.filter((node) => {
      return hasUsableAddress(node)
    })

    const applied: string[] = []
    for (const node of candidates) {
      const subscription = subscriptionId(node.instanceId)
      if (existingSubscriptionIds.has(subscription)) {
        // Already applied to the active profile
        continue
      }

      try {
        await applyNodeToProfile(node)
        markNodeStatus(node.instanceId, 'connected')
        applied.push(node.instanceId)
        existingSubscriptionIds.add(subscription)
      } catch (error) {
        logError('[CloudStore] Auto-apply failed for node:', node.label, error)
      }
    }

    if (applied.length) {
      try {
        if (kernelApiStore.running) {
          await kernelApiStore.restartCore()
          await kernelApiStore.refreshProviderProxies().catch((error) =>
            logError('[CloudStore] Failed to refresh provider proxies after auto-apply:', error),
          )
        } else {
          await kernelApiStore.startCore()
          await kernelApiStore.refreshProviderProxies().catch((error) =>
            logError('[CloudStore] Failed to refresh provider proxies after auto-apply:', error),
          )
        }
      } catch (error) {
        logError('[CloudStore] Failed to restart core after auto-applying nodes:', error)
      }
    } else if (!kernelApiStore.running && candidates.length > 0) {
      // Only try to start core if we have a valid profile
      const profileId = appSettingsStore.app.kernel.profile
      const hasValidProfile = profileId && profilesStore.getProfileById(profileId)

      if (hasValidProfile) {
        try {
          await kernelApiStore.startCore()
          await kernelApiStore.refreshProviderProxies().catch((error) =>
            logError('[CloudStore] Failed to refresh provider proxies after auto-start:', error),
          )
        } catch (error) {
          logError('[CloudStore] Failed to start core when applying existing nodes:', error)
        }
      } else {
        logInfo('[CloudStore] Skipping auto-start: no valid profile configured')
      }
    }

    return applied
  }

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

        // Only auto-start if we have a valid profile
        const profileId = appSettingsStore.app.kernel.profile
        const hasValidProfile = profileId && profilesStore.getProfileById(profileId)

        if (!kernelApiStore.running && hasReadyInstances.value && hasValidProfile) {
          await kernelApiStore.startCore()
          await kernelApiStore.refreshProviderProxies().catch((error) =>
            logError('[CloudStore] Failed to refresh provider proxies after auto-start:', error),
          )
        } else if (!kernelApiStore.running && hasReadyInstances.value && !hasValidProfile) {
          logInfo('[CloudStore] Skipping auto-start in watch: no valid profile configured')
        }
      } catch (error) {
        logError('[CloudStore] Auto-start kernel failed:', error)
      } finally {
        autoStartKernelLock = false
      }
    },
    { immediate: true },
  )

  const applyNodeToProfile = async (node: CloudNode, profileId?: string) => {
    await ensureSubscriptionForNode(node)

    const subscription = subscribesStore.getSubscribeById(subscriptionId(node.instanceId))
    if (!subscription) {
      throw new Error(`Subscription for ${node.label} is missing`)
    }

    const targetProfileId = profileId || appSettingsStore.app.kernel.profile
    let baseProfile: IProfile | undefined = targetProfileId
      ? profilesStore.getProfileById(targetProfileId)
      : undefined

    let created = false
    if (!baseProfile || baseProfile.outbounds.every((outbound: IOutbound) => outbound.type !== Outbound.Selector)) {
      baseProfile = {
        id: sampleID(),
        name: node.label,
        log: ProfileDefaults.DefaultLog(),
        experimental: ProfileDefaults.DefaultExperimental(),
        inbounds: ProfileDefaults.DefaultInbounds(),
        outbounds: ProfileDefaults.DefaultOutbounds(),
        route: ProfileDefaults.DefaultRoute(),
        dns: ProfileDefaults.DefaultDns(),
        mixin: ProfileDefaults.DefaultMixin(),
        script: ProfileDefaults.DefaultScript(),
      }
      created = true
    } else {
      baseProfile = deepClone(baseProfile)
    }

    const profile = baseProfile as IProfile
    const proxyEntry = {
      id: subscription.id,
      tag: subscription.name || node.label,
      type: 'Subscription',
    }

    const appendProxy = (outbound: IOutbound) => {
      const current = outbound.outbounds
      if (!Array.isArray(current)) {
        if (current && typeof (current as any).map === 'function') {
          outbound.outbounds = (current as any).map((item: any) => ({ ...item }))
        } else if (Array.isArray((current as any)?.items)) {
          outbound.outbounds = ((current as any).items as any[]).map((item: any) => ({ ...item }))
        } else {
          outbound.outbounds = []
        }
      }
      if (!Array.isArray(outbound.outbounds)) {
        outbound.outbounds = []
      }
      if (!outbound.outbounds.find((item) => item.id === proxyEntry.id)) {
        outbound.outbounds.push({ ...proxyEntry })
      }
    }

    const selectorOutbounds = profile.outbounds.filter((outbound: IOutbound) => outbound.type === Outbound.Selector)
    if (selectorOutbounds.length === 0) {
      const outbound = ProfileDefaults.DefaultOutbound()
      outbound.id = sampleID()
      outbound.tag = proxyEntry.tag
      outbound.type = Outbound.Selector
      outbound.outbounds = [{ ...proxyEntry }]
      profile.outbounds.push(outbound)
    } else {
      selectorOutbounds.forEach(appendProxy)
    }

    const urltestOutbounds = profile.outbounds.filter((outbound: IOutbound) => outbound.type === Outbound.Urltest)
    if (urltestOutbounds.length === 0) {
      const outbound = ProfileDefaults.DefaultOutbound()
      outbound.id = sampleID()
      outbound.tag = `${proxyEntry.tag}-urltest`
      outbound.type = Outbound.Urltest
      outbound.outbounds = [{ ...proxyEntry }]
      profile.outbounds.push(outbound)
    } else {
      urltestOutbounds.forEach(appendProxy)
    }

    profile.route.final = profile.route.final || ProfileDefaults.DefaultRoute().final

    if (created) {
      await profilesStore.addProfile(profile)
    } else {
      await profilesStore.editProfile(profile.id, profile)
    }

    appSettingsStore.app.kernel.profile = profile.id

    return profile.id
  }

  // Multi-cloud provider methods
  const loadProviders = async () => {
    try {
      if (typeof ListCloudProviders !== 'function') {
        console.warn('[CloudStore] ListCloudProviders not available, using default')
        availableProviders.value = [{ name: 'vultr', displayName: 'Vultr' }]
        return
      }

      const res = await ListCloudProviders()
      if (res.flag) {
        availableProviders.value = parseJSON<Array<{ name: string; displayName: string }>>(res.data, [])
        console.log('[CloudStore] Loaded providers:', availableProviders.value)
      }
    } catch (error) {
      logError('[CloudStore] Failed to load providers:', error)
      availableProviders.value = [{ name: 'vultr', displayName: 'Vultr' }]
    }
  }

  const switchProvider = async (provider: CloudProvider) => {
    try {
      // Save current provider's API key before switching
      if (config.apiKey && currentProvider.value) {
        await saveConfig()
      }

      // Reset config while loading new provider to avoid using stale credentials
      Object.assign(config, {
        apiKey: '',
        defaultPlan: '',
        defaultRegion: '',
        provider: provider,
        extra: {},
      })
      stopAutoRefresh()

      if (typeof SetCloudProvider !== 'function') {
        console.warn('[CloudStore] SetCloudProvider not available')
        currentProvider.value = provider
        return
      }

      const res = await SetCloudProvider(provider)
      ensureFlag(res.flag, res.data)
      currentProvider.value = provider
      console.log('[CloudStore] Switched to provider:', provider)

      // Clear current data when switching providers
      regions.value = []
      plans.value = []
      instances.value = []
      instancesUpdatedAt.value = Date.now()
      Object.keys(availability).forEach((key) => delete availability[key])

      // Reload config and data for new provider (will load saved API key)
      await loadConfig()
      console.log('[CloudStore] After loadConfig, defaultRegion:', config.defaultRegion, 'defaultPlan:', config.defaultPlan)

      // Clear provider-specific defaults since region/plan IDs are not portable across providers
      config.defaultRegion = ''
      config.defaultPlan = ''
      console.log('[CloudStore] Cleared defaults, defaultRegion:', config.defaultRegion, 'defaultPlan:', config.defaultPlan)

      if (config.apiKey) {
        // Refresh regions, plans, and instances for the new provider
        await Promise.all([fetchRegions(), fetchPlans()])
        console.log('[CloudStore] After fetching, regions count:', regions.value.length, 'plans count:', plans.value.length)
        await refreshInstances(true)
      }
    } catch (error) {
      logError('[CloudStore] Failed to switch provider:', error)
      throw error
    }
  }

  const getCurrentProvider = async () => {
    try {
      if (typeof GetCloudProvider !== 'function') {
        console.warn('[CloudStore] GetCloudProvider not available, using default')
        return
      }

      const res = await GetCloudProvider()
      if (res.flag) {
        const provider = parseJSON<{ name: string; displayName: string }>(res.data, { name: 'vultr', displayName: 'Vultr' })
        currentProvider.value = provider.name as CloudProvider
        console.log('[CloudStore] Current provider:', provider)
      }
    } catch (error) {
      logError('[CloudStore] Failed to get current provider:', error)
    }
  }

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
    destroyInstance,
    rotateIP,
    applyNodeToProfile,
    applyAllNodesToProfile,
    startAutoRefresh,
    stopAutoRefresh,
    clearAllTimers,  // 新增：清理所有定时器
    testNodeConnectivity,
    testAllNodesConnectivity,
    addManualNode,
    addManualNodes,
    updateManualNode,
    loadManualNodes,
    instancesUpdatedAt,
  }
})
const isPublicIPv4Address = (ip?: string) => {
  if (!ip) return false
  const octets = ip.split('.')
  if (octets.length !== 4) return false

  const first = parseInt(octets[0], 10)
  const second = parseInt(octets[1], 10)

  // CGNAT range: 100.64.0.0/10 (100.64.0.0 - 100.127.255.255)
  if (first === 100 && second >= 64 && second <= 127) return false

  // Private ranges
  if (first === 10) return false // 10.0.0.0/8
  if (first === 192 && second === 168) return false // 192.168.0.0/16
  if (first === 172 && second >= 16 && second <= 31) return false // 172.16.0.0/12

  if (ip === '0.0.0.0') return false

  return true
}

const hasUsableAddress = (node: ManagedCloudNode) =>
  (isPublicIPv4Address(node.ipv4) || (!!node.ipv6 && node.ipv6 !== '::')) && !!node.instanceId
