/**
 * Cloud Store - Subscription & Profile Apply
 *
 * Handles subscription generation for cloud nodes, applying nodes to profiles,
 * protocol health management, and syncing managed cloud profiles.
 */


import { ReadFile, WriteFile, RemoveFile } from '@/bridge'
import { DefaultSubscribeScript } from '@/constant/app'
import { DefaultExcludeProtocols } from '@/constant/kernel'
import * as ProfileDefaults from '@/constant/profile'
import { RequestMethod } from '@/enums/app'
import { Outbound } from '@/enums/kernel'
import { sampleID, deepClone, ignoredError, debounce } from '@/utils'
import { logError, logInfo } from '@/utils/logger'


import {
  DefaultHysteriaServerName,
  DefaultVlessServerName,
  DefaultTrojanServerName,
  protocolHealthPath,
  type ManagedProtocol,
  type ProtocolHealthState,
  type ProtocolHealthReason,
  type ProtocolHealthMap,
} from './constants'
import {
  parseJSON,
  subscriptionId,
  subscriptionPath,
  normalizeServerName,
  resolveTLSInsecure,
  isReachableTargetStatus,
  joinRegexAlternatives,
  deriveManagedExclude,
  isPublicIPv4Address,
  hasUsableAddress,
} from './helpers'
import { ensureSmartAutoRouting } from './smartRouting'

import type { ManagedCloudNode } from './types'
import type { Subscription } from '@/types/app'
import type { CloudNode, ConnectivityResult } from '@/types/cloud'
import type { Ref, ShallowRef } from 'vue'

export type SubscriptionApplyDeps = {
  protocolHealth: ShallowRef<ProtocolHealthMap>
  protocolHealthLoaded: Ref<boolean>
  subscribesStore: {
    getSubscribeById: (id: string) => Subscription | undefined
    addSubscribe: (sub: Subscription) => Promise<void>
    editSubscribe: (id: string, sub: Subscription) => Promise<void>
    deleteSubscribe: (id: string) => Promise<void>
    subscribes: Subscription[]
  }
  profilesStore: {
    profiles: IProfile[]
    getProfileById: (id: string) => IProfile | undefined
    addProfile: (profile: IProfile) => Promise<void>
    editProfile: (id: string, profile: IProfile) => Promise<void>
  }
  appSettingsStore: {
    app: {
      kernel: { profile: string }
      autoStartKernel: boolean
    }
  }
  kernelApiStore: {
    running: boolean
    restartCore: () => Promise<void>
    startCore: () => Promise<void>
    refreshProviderProxies: () => Promise<void>
    removeProxyFromGroups: (id: string) => void
  }
  reloadKernel: (reason: string, options?: { allowStartWhenStopped?: boolean }) => Promise<void>
}

export function createSubscriptionApply(deps: SubscriptionApplyDeps) {
  const {
    protocolHealth,
    protocolHealthLoaded,
    subscribesStore,
    profilesStore,
    appSettingsStore,
    kernelApiStore,
    reloadKernel,
  } = deps

  const loadProtocolHealth = async () => {
    if (protocolHealthLoaded.value) {
      return protocolHealth.value
    }
    protocolHealthLoaded.value = true
    const content = await ignoredError(ReadFile, protocolHealthPath)
    protocolHealth.value = content ? parseJSON<ProtocolHealthMap>(content, {}) : {}
    return protocolHealth.value
  }

  const saveProtocolHealthImmediate = async () => {
    await WriteFile(protocolHealthPath, JSON.stringify(protocolHealth.value, null, 2))
  }
  const saveProtocolHealth = debounce(saveProtocolHealthImmediate, 1000)

  const getProtocolHealthEntry = (instanceId: string) => protocolHealth.value[instanceId] || {}

  const applyManagedExcludeToSubscription = (subscription: Subscription, instanceId: string) => {
    const managedExclude = deriveManagedExclude(getProtocolHealthEntry(instanceId))
    subscription.header = subscription.header || { request: {}, response: {} }
    subscription.header.request = subscription.header.request || {}
    subscription.header.response = subscription.header.response || {}

    const userExcludeKey = 'x-privatedeploy-user-exclude'
    const managedExcludeKey = 'x-privatedeploy-managed-exclude'
    const existingManaged = subscription.header.response[managedExcludeKey]
    const preservedUserExclude =
      existingManaged !== undefined
        ? subscription.header.response[userExcludeKey] || ''
        : subscription.exclude || ''

    subscription.header.response[userExcludeKey] = preservedUserExclude
    subscription.header.response[managedExcludeKey] = managedExclude
    subscription.exclude = joinRegexAlternatives(preservedUserExclude, managedExclude)
  }

  const setProtocolHealthEntry = async (
    instanceId: string,
    protocol: ManagedProtocol,
    nextState: ProtocolHealthState,
    reason: ProtocolHealthReason,
  ) => {
    await loadProtocolHealth()
    const current = { ...protocolHealth.value[instanceId] }
    const existing = current[protocol]
    if (existing?.state === nextState && existing.reason === reason) {
      return false
    }
    current[protocol] = {
      state: nextState,
      reason,
      updatedAt: Date.now(),
    }
    protocolHealth.value = {
      ...protocolHealth.value,
      [instanceId]: current,
    }
    await saveProtocolHealth()
    return true
  }

  const migrateProtocolHealthEntry = async (fromInstanceId: string, toInstanceId: string) => {
    if (!fromInstanceId || !toInstanceId || fromInstanceId === toInstanceId) {
      return false
    }

    await loadProtocolHealth()
    const source = protocolHealth.value[fromInstanceId]
    if (!source) {
      return false
    }

    const target = protocolHealth.value[toInstanceId] || {}
    const nextHealth = {
      ...protocolHealth.value,
      [toInstanceId]: {
        ...source,
        ...target,
      },
    }
    delete nextHealth[fromInstanceId]
    protocolHealth.value = nextHealth
    await saveProtocolHealthImmediate()
    return true
  }

  const syncManagedCloudProfiles = async (reason: string, allowStartWhenStopped = false) => {
    let changed = false
    const updates: Array<Promise<void>> = []

    for (const profile of profilesStore.profiles) {
      if (!profile) continue
      const updated = deepClone(profile)
      ensureSmartAutoRouting(updated, protocolHealth.value)
      if (JSON.stringify(updated) === JSON.stringify(profile)) {
        continue
      }
      changed = true
      updates.push(profilesStore.editProfile(profile.id, updated))
    }

    if (!changed) {
      return false
    }

    await Promise.all(updates)
    await reloadKernel(reason, { allowStartWhenStopped })
    return true
  }

  const ensureSubscriptionForNode = async (node: CloudNode) => {
    await loadProtocolHealth()
    // Check if we have at least one IP address
    if (!hasUsableAddress(node)) {
      await removeSubscriptionForNode(node.instanceId)
      return
    }

    const id = subscriptionId(node.instanceId)
    const path = subscriptionPath(node.instanceId)

    // Build outbounds array with all available protocols
    const outbounds: any[] = []

    const hasIPv4 = !!node.ipv4 && node.ipv4 !== '' && isPublicIPv4Address(node.ipv4)
    const hasIPv6 = !!node.ipv6 && node.ipv6 !== ''
    const ipVersions: Array<{ ip: string; suffix: string }> = []

    if (hasIPv4 && node.ipv4) {
      ipVersions.push({ ip: node.ipv4, suffix: '-v4' })
    }
    if (hasIPv6 && node.ipv6) {
      ipVersions.push({ ip: node.ipv6, suffix: '-v6' })
    }

    if (ipVersions.length === 0) {
      console.log(`[CloudStore] Node ${node.label} has no usable public IP addresses, skipping subscription generation`)
      await removeSubscriptionForNode(node.instanceId)
      return
    }

    const hysteriaServerName = normalizeServerName(node.hysteriaServerName, DefaultHysteriaServerName)
    const hysteriaInsecure = resolveTLSInsecure(node, 'hysteria')
    const vlessServerName = normalizeServerName(node.vlessServerName, DefaultVlessServerName)
    const trojanServerName = normalizeServerName(node.trojanServerName, DefaultTrojanServerName)
    const trojanInsecure = resolveTLSInsecure(node, 'trojan')

    // 1. Shadowsocks
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

    // 2. Hysteria2
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
            insecure: hysteriaInsecure,
            server_name: hysteriaServerName,
          },
        })
      })
    }

    // 3. VLESS-Reality
    if (node.vlessPort && node.vlessUUID && node.vlessPublicKey && node.vlessShortId) {
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
            server_name: vlessServerName,
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

    // 4. Trojan
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
            insecure: trojanInsecure,
            server_name: trojanServerName,
          },
        })
      })
    }

    // Fallback: legacy format
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

    const payload = {
      outbounds,
    }

    const newContent = JSON.stringify(payload, null, 2)
    const existing = subscribesStore.getSubscribeById(id)

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
    subscription.includeProtocol = subscription.includeProtocol || ''
    subscription.proxyPrefix = subscription.proxyPrefix || ''
    subscription.header = subscription.header || { request: {}, response: {} }
    subscription.header.request = subscription.header.request || {}
    subscription.header.response = subscription.header.response || {}
    subscription.proxies = subscription.proxies || []
    applyManagedExcludeToSubscription(subscription, node.instanceId)

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

    // Optimistic UI update: immediately remove from proxy groups for instant feedback
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
        ensureSmartAutoRouting(updated, protocolHealth.value)
        toPrune.push(profilesStore.editProfile(profile.id, updated))
      }
    }

    if (toPrune.length > 0) {
      await Promise.all(toPrune)
      if (kernelApiStore.running) {
        try {
          await reloadKernel('remove-subscription', { allowStartWhenStopped: false })
          logInfo('[CloudStore] Core restarted after removing subscription:', id)
        } catch (error) {
          logError('[CloudStore] Failed to restart core after pruning subscription:', error)
        }
      }
    }
  }

  const replaceSubscriptionReferences = async (
    oldSubscriptionId: string,
    newSubscriptionId: string,
    nextTag: string,
  ) => {
    if (!oldSubscriptionId || !newSubscriptionId || oldSubscriptionId === newSubscriptionId) {
      return false
    }

    let changed = false
    const updates: Array<Promise<void>> = []

    for (const profile of profilesStore.profiles) {
      if (!profile) continue
      let profileChanged = false
      const updated = deepClone(profile)

      const replaceItems = (items: Array<any> | undefined) => {
        if (!Array.isArray(items)) {
          return items
        }

        const next: any[] = []
        const seenIds = new Set<string>()
        for (const item of items) {
          if (!item || typeof item !== 'object') {
            next.push(item)
            continue
          }

          const nextItem = item.id === oldSubscriptionId
            ? { ...item, id: newSubscriptionId, tag: nextTag || item.tag }
            : { ...item }

          if (item.id === oldSubscriptionId) {
            profileChanged = true
          }

          const dedupeKey = typeof nextItem.id === 'string' ? nextItem.id : ''
          if (dedupeKey && seenIds.has(dedupeKey)) {
            profileChanged = true
            continue
          }
          if (dedupeKey) {
            seenIds.add(dedupeKey)
          }
          next.push(nextItem)
        }

        return next
      }

      updated.outbounds = updated.outbounds.map((outbound: IOutbound) => {
        const nextOutbound = { ...outbound }
        if (nextOutbound.id === oldSubscriptionId) {
          nextOutbound.id = newSubscriptionId
          nextOutbound.tag = nextTag || nextOutbound.tag
          profileChanged = true
        }
        nextOutbound.outbounds = replaceItems(nextOutbound.outbounds) as any
        return nextOutbound
      })

      if (profileChanged) {
        ensureSmartAutoRouting(updated, protocolHealth.value)
        updates.push(profilesStore.editProfile(profile.id, updated))
        changed = true
      }
    }

    if (updates.length > 0) {
      await Promise.all(updates)
    }

    return changed
  }

  const migrateManagedNodeIdentity = async (
    fromInstanceId: string,
    node: CloudNode,
  ) => {
    if (!fromInstanceId || fromInstanceId === node.instanceId) {
      return false
    }

    const oldSubscriptionId = subscriptionId(fromInstanceId)
    const newSubscriptionId = subscriptionId(node.instanceId)
    const oldSubscription = subscribesStore.getSubscribeById(oldSubscriptionId)

    let changed = await migrateProtocolHealthEntry(fromInstanceId, node.instanceId)

    await ensureSubscriptionForNode(node)

    const newSubscription = subscribesStore.getSubscribeById(newSubscriptionId)
    if (newSubscription && oldSubscription) {
      const migratedSubscription: Subscription = {
        ...oldSubscription,
        id: newSubscriptionId,
        name: node.label,
        path: subscriptionPath(node.instanceId),
        updateTime: Date.now(),
        script: newSubscription.script || oldSubscription.script || DefaultSubscribeScript,
        proxies: newSubscription.proxies,
        header: {
          request: {
            ...oldSubscription.header?.request,
          },
          response: {
            ...oldSubscription.header?.response,
          },
        },
      }
      applyManagedExcludeToSubscription(migratedSubscription, node.instanceId)
      await subscribesStore.editSubscribe(newSubscriptionId, migratedSubscription)
      changed = true
    }

    const nextTag = newSubscription?.name || node.label
    if (await replaceSubscriptionReferences(oldSubscriptionId, newSubscriptionId, nextTag)) {
      changed = true
    }

    if (oldSubscription) {
      await subscribesStore.deleteSubscribe(oldSubscriptionId)
      changed = true
    }
    await RemoveFile(subscriptionPath(fromInstanceId)).catch(() => undefined)
    kernelApiStore.removeProxyFromGroups(oldSubscriptionId)

    return changed
  }

  const applyProtocolHealthToNode = async (node: CloudNode) => {
    await loadProtocolHealth()
    const existing = subscribesStore.getSubscribeById(subscriptionId(node.instanceId))
    if (!existing) {
      return
    }
    await ensureSubscriptionForNode(node)
    const changed = await syncManagedCloudProfiles('protocol-health-update', false)
    if (!changed && kernelApiStore.running) {
      await kernelApiStore.refreshProviderProxies().catch((error) =>
        logError('[CloudStore] Failed to refresh provider proxies after protocol health update:', error),
      )
    }
  }

  const updateProtocolHealthFromConnectivity = async (node: CloudNode, result: ConnectivityResult) => {
    await loadProtocolHealth()
    const targetStatus = result.targetStatus || {}
    const tcpOpen = {
      shadowsocks: isReachableTargetStatus(targetStatus['shadowsocks-tcp']),
      vless: isReachableTargetStatus(targetStatus['vless-reality']),
      trojan: isReachableTargetStatus(targetStatus['trojan']),
    }
    const anyTCPReachable = Object.values(tcpOpen).some(Boolean)
    const next: Array<[ManagedProtocol, ProtocolHealthState, ProtocolHealthReason]> = []

    if (node.hysteriaPort) {
      next.push([
        'hysteria2',
        anyTCPReachable && !isReachableTargetStatus(targetStatus['hysteria2']) ? 'degraded' : 'healthy',
        'connectivity-udp-unreachable',
      ])
    }
    if (node.ssPort) {
      next.push([
        'shadowsocks',
        Object.values({ vless: tcpOpen.vless, trojan: tcpOpen.trojan }).some(Boolean) && !tcpOpen.shadowsocks
          ? 'degraded'
          : 'healthy',
        'connectivity-tcp-unreachable',
      ])
    }
    if (node.vlessPort) {
      next.push([
        'vless',
        Object.values({ shadowsocks: tcpOpen.shadowsocks, trojan: tcpOpen.trojan }).some(Boolean) && !tcpOpen.vless
          ? 'degraded'
          : 'healthy',
        'connectivity-tcp-unreachable',
      ])
    }
    if (node.trojanPort) {
      next.push([
        'trojan',
        Object.values({ shadowsocks: tcpOpen.shadowsocks, vless: tcpOpen.vless }).some(Boolean) && !tcpOpen.trojan
          ? 'degraded'
          : 'healthy',
        'connectivity-tcp-unreachable',
      ])
    }

    let changed = false
    for (const [protocol, state, reason] of next) {
      changed = (await setProtocolHealthEntry(node.instanceId, protocol, state, reason)) || changed
    }

    if (changed) {
      await applyProtocolHealthToNode(node)
    }
  }

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
    ensureSmartAutoRouting(profile, protocolHealth.value)

    if (created) {
      await profilesStore.addProfile(profile)
    } else {
      await profilesStore.editProfile(profile.id, profile)
    }

    appSettingsStore.app.kernel.profile = profile.id

    return profile.id
  }

  const applyAllNodesToProfile = async (
    instancesRef: ShallowRef<ManagedCloudNode[]>,
    loadManualNodes: () => Promise<ManagedCloudNode[]>,
    syncManualNodesIntoInstances: () => void,
    markNodeStatus: (instanceId: string, status: import('./constants').CloudNodeStatus) => void,
  ) => {
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

    const candidates = instancesRef.value.filter((node) => {
      return hasUsableAddress(node)
    })

    const applied: string[] = []
    for (const node of candidates) {
      const subscription = subscriptionId(node.instanceId)
      if (existingSubscriptionIds.has(subscription)) {
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
        await reloadKernel('apply-all-nodes')
      } catch (error) {
        logError('[CloudStore] Failed to restart core after auto-applying nodes:', error)
      }
    } else if (!kernelApiStore.running && candidates.length > 0) {
      try {
        await reloadKernel('apply-existing-ready-nodes')
      } catch (error) {
        logError('[CloudStore] Failed to start core when applying existing nodes:', error)
      }
    }

    return applied
  }

  return {
    loadProtocolHealth,
    ensureSubscriptionForNode,
    removeSubscriptionForNode,
    migrateManagedNodeIdentity,
    applyNodeToProfile,
    applyAllNodesToProfile,
    syncManagedCloudProfiles,
    updateProtocolHealthFromConnectivity,
  }
}
