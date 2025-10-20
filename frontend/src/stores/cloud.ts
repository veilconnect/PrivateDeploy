import { defineStore } from 'pinia'
import { reactive, ref } from 'vue'

import {
  GetVultrConfig,
  SaveVultrConfig,
  ListVultrRegions,
  ListVultrPlans,
  ListVultrInstances,
  CreateVultrInstance,
  DestroyVultrInstance,
  ListVultrAvailability,
  ListCloudProviders,
  GetCloudProvider,
  SetCloudProvider,
  WriteFile,
  RemoveFile,
} from '@/bridge'
import { DefaultSubscribeScript } from '@/constant/app'
import { DefaultExcludeProtocols } from '@/constant/kernel'
import * as ProfileDefaults from '@/constant/profile'
import { RequestMethod } from '@/enums/app'
import { Outbound } from '@/enums/kernel'
import { sampleID, deepClone } from '@/utils'
import { logError } from '@/utils/logger'

import { useSubscribesStore } from './subscribes'
import { useProfilesStore } from './profiles'
import { useAppSettingsStore } from './appSettings'

import type { Subscription } from '@/types/app'
import type { CloudProvider, VultrConfig, VultrNode, VultrPlan, VultrRegion } from '@/types/cloud'


type CloudNodeStatus = 'unknown' | 'pending' | 'applying' | 'connected' | 'error'
type CloudNode = VultrNode & { statusText?: CloudNodeStatus }
const parseJSON = <T>(data: string | undefined | null, fallback: T): T => {
  if (!data) return fallback
  try {
    return JSON.parse(data) as T
  } catch (error) {
    logError('Failed to parse Vultr response', error)
    return fallback
  }
}

const subscriptionId = (instanceId: string) => `cloud-${instanceId}`
const subscriptionPath = (instanceId: string) => `data/subscribes/cloud-${instanceId}.json`

export const useCloudStore = defineStore('cloud', () => {
  // Multi-cloud provider management
  const availableProviders = ref<Array<{ name: string; displayName: string }>>([])
  const currentProvider = ref<CloudProvider>('vultr')

  const config = reactive<VultrConfig>({
    apiKey: '',
    defaultPlan: '',
    defaultRegion: '',
  })
  const configLoaded = ref(false)
  const savingConfig = ref(false)

  const regions = ref<VultrRegion[]>([])
  const plans = ref<VultrPlan[]>([])
  const availability = reactive<Record<string, string[]>>({})
  const instances = ref<CloudNode[]>([])

  const loadingRegions = ref(false)
  const loadingPlans = ref(false)
  const loadingInstances = ref(false)
  const creatingInstance = ref(false)
  const destroyingInstance = ref<string>('')

  const subscribesStore = useSubscribesStore()
  const profilesStore = useProfilesStore()
  const appSettingsStore = useAppSettingsStore()

  const ensureFlag = (flag: boolean, data: string) => {
    if (!flag) throw new Error(data)
  }

  const ensureRegionAvailability = async (region: string, force = false) => {
    if (!region) return [] as string[]
    if (typeof ListVultrAvailability !== 'function') {
      availability[region] = availability[region] || []
      return availability[region]
    }
    if (force || !availability[region]) {
      const res = await ListVultrAvailability(region)
      ensureFlag(res.flag, res.data)
      availability[region] = parseJSON<string[]>(res.data, [])
    }
    return availability[region]
  }

  const ensureSubscriptionForNode = async (node: VultrNode) => {
    // Check if we have at least one IP address
    if (!node.instanceId || (!node.ipv4 && !node.ipv6)) return

    const id = subscriptionId(node.instanceId)
    const path = subscriptionPath(node.instanceId)

    // Build outbounds array with all available protocols
    // For each protocol, if both IPv4 and IPv6 are available, create separate nodes
    const outbounds: any[] = []

    // Determine which IP versions are available for proxy configuration
    // Filter out private/internal IPs (100.64.0.0/10 CGNAT, 10.0.0.0/8, 192.168.0.0/16, 172.16.0.0/12)
    const isPublicIPv4 = (ip: string): boolean => {
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

      return true
    }

    const hasIPv4 = !!node.ipv4 && node.ipv4 !== '' && isPublicIPv4(node.ipv4)
    const hasIPv6 = !!node.ipv6 && node.ipv6 !== ''
    const ipVersions: Array<{ ip: string; suffix: string }> = []

    // Generate configurations for all available public IPs
    // sing-box will automatically try available connections
    if (hasIPv4) {
      ipVersions.push({ ip: node.ipv4, suffix: '-v4' })
    }
    if (hasIPv6 && node.ipv6) {
      ipVersions.push({ ip: node.ipv6, suffix: '-v6' })
    }

    // Skip nodes with only internal/private IPs - they cannot be used for external connections
    if (ipVersions.length === 0) {
      console.log(`[CloudStore] Node ${node.label} has no usable public IP addresses, skipping subscription generation`)
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
    if (outbounds.length === 0 && node.port && node.password) {
      ipVersions.forEach(({ ip, suffix }) => {
        outbounds.push({
          type: 'shadowsocks',
          tag: `${node.label}${suffix}`,
          server: ip,
          server_port: node.port,
          method: 'aes-256-gcm',
          password: node.password,
        })
      })
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

  const removeSubscriptionForNode = async (instanceId: string) => {
    const id = subscriptionId(instanceId)
    const path = subscriptionPath(instanceId)
    const existing = subscribesStore.getSubscribeById(id)
    if (existing) {
      await subscribesStore.deleteSubscribe(id)
    }
    await RemoveFile(path).catch(() => undefined)
  }

  const loadConfig = async () => {
    const res = await GetVultrConfig()
    ensureFlag(res.flag, res.data)
    Object.assign(config, {
      apiKey: '',
      defaultPlan: '',
      defaultRegion: '',
    })
    Object.assign(config, parseJSON<VultrConfig>(res.data, {} as VultrConfig))
    configLoaded.value = true
  }

  const saveConfig = async () => {
    savingConfig.value = true
    try {
      const res = await SaveVultrConfig(JSON.stringify(config))
      ensureFlag(res.flag, res.data)
    } finally {
      savingConfig.value = false
    }
  }

  const fetchRegions = async () => {
    loadingRegions.value = true
    try {
      const res = await ListVultrRegions()
      ensureFlag(res.flag, res.data)
      regions.value = parseJSON<VultrRegion[]>(res.data, [])
    } finally {
      loadingRegions.value = false
    }
  }

  const fetchPlans = async () => {
    loadingPlans.value = true
    try {
      const res = await ListVultrPlans()
      ensureFlag(res.flag, res.data)
      plans.value = parseJSON<VultrPlan[]>(res.data, [])
    } finally {
      loadingPlans.value = false
    }
  }

  const refreshInstances = async (silent = false) => {
    if (!silent) {
      loadingInstances.value = true
    }
    try {
      const res = await ListVultrInstances()
      ensureFlag(res.flag, res.data)
      const rawNodes = parseJSON<VultrNode[]>(res.data, [])

      await Promise.all(rawNodes.map((node) => ensureRegionAvailability(node.region).catch(() => [])))

      const statusMap = new Map(instances.value.map((node) => [node.instanceId, node.statusText || 'unknown']))
      const enriched: CloudNode[] = rawNodes.map((node) => ({
        ...node,
        statusText: statusMap.get(node.instanceId) || 'unknown',
      }))

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

      await Promise.all(
        enriched
          .filter((node) => node.instanceId && (node.ipv4 || node.ipv6))
          .map((node) => ensureSubscriptionForNode(node).catch((error) => {
            logError('[CloudStore] Failed to create subscription for node:', node.label, error)
            return undefined
          })),
      )
    } catch (error) {
      logError('[CloudStore] refreshInstances error:', error)
      throw error
    } finally {
      if (!silent) {
        loadingInstances.value = false
      }
    }
  }

  const createInstance = async (options: { label: string; region: string; plan: string }) => {
    creatingInstance.value = true
    try {
      const res = await CreateVultrInstance(JSON.stringify(options))
      ensureFlag(res.flag, res.data)
      const node = parseJSON<VultrNode>(res.data, {} as VultrNode)
      if (node.instanceId) {
        await ensureRegionAvailability(node.region)
        const cloudNode: CloudNode = { ...node, statusText: 'pending' }
        instances.value = [cloudNode, ...instances.value.filter((n) => n.instanceId !== node.instanceId)]
        await ensureSubscriptionForNode(cloudNode)
      }
      return node
    } finally {
      creatingInstance.value = false
    }
  }

  const destroyInstance = async (instanceId: string) => {
    destroyingInstance.value = instanceId
    try {
      const res = await DestroyVultrInstance(instanceId)
      ensureFlag(res.flag, res.data)
      instances.value = instances.value.filter((node) => node.instanceId !== instanceId)
      await removeSubscriptionForNode(instanceId)
    } finally {
      destroyingInstance.value = ''
    }
  }

  const markNodeStatus = (instanceId: string, status: CloudNodeStatus) => {
    const node = instances.value.find((item) => item.instanceId === instanceId)
    if (!node) return
    ;(node as any).statusText = status
  }

  const applyNodeToProfile = async (node: VultrNode, profileId?: string) => {
    await ensureSubscriptionForNode(node)

    const subscription = subscribesStore.getSubscribeById(subscriptionId(node.instanceId))
    if (!subscription) {
      throw new Error(`Subscription for ${node.label} is missing`)
    }

    let targetProfileId = profileId || appSettingsStore.app.kernel.profile
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
      Object.keys(availability).forEach((key) => delete availability[key])

      // Reload config and data for new provider
      await loadConfig()
      if (config.apiKey) {
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
    createInstance,
    destroyInstance,
    applyNodeToProfile,
  }
})
