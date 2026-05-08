/**
 * Smart Auto Routing
 *
 * Pure functions for generating smart routing outbounds and rules.
 * Extracted from cloud.ts to isolate configuration generation logic
 * from state management.
 */

import * as ProfileDefaults from '@/constant/profile'
import { Inbound, Outbound, RuleAction, RuleType, Strategy } from '@/enums/kernel'

import {
  CloudSmartOutboundIds,
  CloudSmartRuleIds,
  CloudSmartLegacyIds,
  CloudSmartProbeURLPrimary,
  CloudSmartProbeURLSecondary,
  SmartProtocolInclude,
  CloudSubscriptionPrefix,
  type ProtocolHealthMap,
} from './constants'
import {
  isManagedCloudOutboundId,
  nodeSmartOutboundId,
  cloudInstanceIdFromSubscriptionRef,
  deriveManagedExclude,
} from './helpers'

import type { CloudSubscriptionEntry } from './types'

// ─── Profile Outbound Helpers ────────────────────────────────────────────────

const ensureOutbound = (
  profile: IProfile,
  id: string,
  tag: string,
  type: Outbound,
): IOutbound => {
  let outbound = profile.outbounds.find((item) => item.id === id)
  if (!outbound) {
    outbound = ProfileDefaults.DefaultOutbound()
    outbound.id = id
    profile.outbounds.push(outbound)
  }

  outbound.id = id
  outbound.tag = tag
  outbound.type = type
  outbound.interrupt_exist_connections = true
  if (!Array.isArray(outbound.outbounds)) {
    outbound.outbounds = []
  }
  return outbound
}

export const syncSubscriptionEntries = (outbound: IOutbound, entries: IProxy[]) => {
  const preserved = Array.isArray(outbound.outbounds)
    ? outbound.outbounds.filter((item) => item.type !== 'Subscription')
    : []
  outbound.outbounds = [...preserved, ...entries.map((entry) => ({ ...entry }))]
}

export const syncBuiltInEntries = (
  outbound: IOutbound,
  entries: Array<{ id: string; tag: string }>,
) => {
  const preserved = Array.isArray(outbound.outbounds)
    ? outbound.outbounds.filter((item) => item.type !== 'Built-in')
    : []
  outbound.outbounds = [
    ...preserved,
    ...entries.map((entry) => ({
      id: entry.id,
      type: 'Built-in' as const,
      tag: entry.tag,
    })),
  ]
}

const findOutboundTag = (profile: IProfile, id: string) => {
  return profile.outbounds.find((item) => item.id === id)?.tag || id
}

const upsertBuiltInChild = (outbound: IOutbound, child: IProxy, index?: number) => {
  const current = Array.isArray(outbound.outbounds) ? [...outbound.outbounds] : []
  const existingIndex = current.findIndex(
    (item) => item.id === child.id && item.type === 'Built-in',
  )
  if (existingIndex >= 0) {
    current.splice(existingIndex, 1)
  }
  if (typeof index === 'number' && index >= 0 && index <= current.length) {
    current.splice(index, 0, { ...child })
  } else {
    current.push({ ...child })
  }
  outbound.outbounds = current
}

// ─── Subscription Collection ─────────────────────────────────────────────────

export const collectSubscriptionEntries = (
  profile: IProfile,
  healthMap: ProtocolHealthMap,
): CloudSubscriptionEntry[] => {
  const dedup = new Map<string, CloudSubscriptionEntry>()
  profile.outbounds.forEach((outbound) => {
    if (isManagedCloudOutboundId(outbound.id)) {
      return
    }
    if (![Outbound.Selector, Outbound.Urltest].includes(outbound.type as any)) {
      return
    }
    const children = Array.isArray(outbound.outbounds) ? outbound.outbounds : []
    children.forEach((child) => {
      if (
        !child ||
        child.type !== 'Subscription' ||
        !child.id ||
        !child.id.startsWith(CloudSubscriptionPrefix)
      ) {
        return
      }
      const instanceId = cloudInstanceIdFromSubscriptionRef(child.id)
      dedup.set(child.id, {
        id: child.id,
        type: 'Subscription',
        tag: child.tag || child.id,
        instanceId,
        managedExclude: deriveManagedExclude(healthMap[instanceId]),
      })
    })
  })
  return Array.from(dedup.values())
}

// ─── Link Aggregation ────────────────────────────────────────────────────────

export const ensureLinkAggregation = (profile: IProfile, cloudSubscriptionCount: number) => {
  const enableMultipath = cloudSubscriptionCount >= 2

  profile.inbounds.forEach((inbound) => {
    if (![Inbound.Mixed, Inbound.Socks, Inbound.Http].includes(inbound.type as any)) {
      return
    }
    const detail = inbound[inbound.type]
    if (!detail || typeof detail !== 'object' || !('listen' in detail)) return
    if (!detail.listen) return
    detail.listen.tcp_multi_path = enableMultipath
  })

  profile.route.auto_detect_interface = true
}

// ─── Load Balance Support ────────────────────────────────────────────────────

// Cached subscription entries from the last ensureSmartAutoRouting call
let _lastSubscriptionEntries: CloudSubscriptionEntry[] = []

/**
 * Inject per-node SOCKS inbounds and route rules into the final sing-box config
 * for connection-level load balancing.
 *
 * For each cloud node, adds:
 * - A SOCKS inbound on a unique port (basePort + index)
 * - A route rule: inbound tag → node's "Cloud Node X Best Auto" outbound
 *
 * Returns the list of upstream ports for the Go load balancer.
 */
export const injectLoadBalanceConfig = (
  config: Record<string, any>,
  basePort: number,
): number[] => {
  // Discover per-node "Cloud Node X Best Auto" outbounds directly from config
  const nodeOutboundTags = (config.outbounds || [])
    .map((ob: any) => ob.tag as string)
    .filter((tag: string) => tag && tag.startsWith('Cloud Node ') && tag.endsWith(' Best Auto'))

  if (nodeOutboundTags.length < 2) return []

  const ports: number[] = []

  for (let i = 0; i < nodeOutboundTags.length; i++) {
    const outboundTag = nodeOutboundTags[i]
    const port = basePort + i
    const inboundTag = `lb-node-${i}`

    // Add SOCKS inbound for this node
    config.inbounds = config.inbounds || []
    config.inbounds.push({
      type: 'socks',
      tag: inboundTag,
      listen: '127.0.0.1',
      listen_port: port,
    })

    // Add route rule: traffic from this inbound → this node's best outbound
    // Insert at the beginning so it takes priority
    config.route = config.route || {}
    config.route.rules = config.route.rules || []
    config.route.rules.unshift({
      inbound: [inboundTag],
      outbound: outboundTag,
    })

    ports.push(port)
  }

  return ports
}

// ─── Core Smart Routing Function ─────────────────────────────────────────────

export const ensureSmartAutoRouting = (
  profile: IProfile,
  healthMap: ProtocolHealthMap = {},
) => {
  const managedRuleIdSet = new Set([
    ...Object.values(CloudSmartRuleIds),
    ...CloudSmartLegacyIds.Rules,
  ])

  // Clean existing managed outbounds and rules
  profile.outbounds = profile.outbounds.filter(
    (outbound) => !isManagedCloudOutboundId(outbound.id),
  )
  profile.outbounds.forEach((outbound) => {
    if (!Array.isArray(outbound.outbounds)) return
    outbound.outbounds = outbound.outbounds.filter(
      (child) => !isManagedCloudOutboundId(child.id),
    )
  })
  profile.route.rules = profile.route.rules.filter(
    (rule) => !managedRuleIdSet.has(rule.id as any) && !isManagedCloudOutboundId(rule.outbound),
  )

  const subscriptions = collectSubscriptionEntries(profile, healthMap)
  ensureLinkAggregation(profile, subscriptions.length)
  if (subscriptions.length === 0) return

  // Track subscription entries for load balance config injection
  _lastSubscriptionEntries = subscriptions

  // Per-node best protocol auto outbounds
  const nodeAutoOutbounds = subscriptions.map((entry) => {
    const outbound = ensureOutbound(
      profile,
      nodeSmartOutboundId(entry.instanceId),
      `Cloud Node ${entry.tag} Best Auto`,
      Outbound.Urltest,
    )
    syncSubscriptionEntries(outbound, [entry])
    outbound.url = CloudSmartProbeURLPrimary
    outbound.include = SmartProtocolInclude.NodeBest
    outbound.exclude = entry.managedExclude
    outbound.interval = outbound.interval || '75s'
    outbound.tolerance = Math.max(65, Number(outbound.tolerance || 0))
    return {
      id: outbound.id,
      tag: outbound.tag,
    }
  })

  // Global smart outbounds
  const auto = ensureOutbound(
    profile,
    CloudSmartOutboundIds.Auto,
    'Cloud Smart Best Auto',
    Outbound.Urltest,
  )
  syncBuiltInEntries(auto, nodeAutoOutbounds)
  auto.url = CloudSmartProbeURLPrimary
  auto.include = ''
  auto.exclude = ''
  auto.interval = auto.interval || '2m'
  auto.tolerance = Math.max(80, Number(auto.tolerance || 0))

  const tcpPrimary = ensureOutbound(
    profile,
    CloudSmartOutboundIds.TcpPrimary,
    'Cloud Smart Best TCP Auto',
    Outbound.Urltest,
  )
  syncBuiltInEntries(tcpPrimary, nodeAutoOutbounds)
  tcpPrimary.url = CloudSmartProbeURLPrimary
  tcpPrimary.include = ''
  tcpPrimary.exclude = ''
  tcpPrimary.interval = tcpPrimary.interval || '90s'
  tcpPrimary.tolerance = Math.max(70, Number(tcpPrimary.tolerance || 0))

  const tcpSecondary = ensureOutbound(
    profile,
    CloudSmartOutboundIds.TcpSecondary,
    'Cloud Smart Best Web Auto',
    Outbound.Urltest,
  )
  syncBuiltInEntries(tcpSecondary, nodeAutoOutbounds)
  tcpSecondary.url = CloudSmartProbeURLSecondary
  tcpSecondary.include = ''
  tcpSecondary.exclude = ''
  tcpSecondary.interval = tcpSecondary.interval || '90s'
  tcpSecondary.tolerance = Math.max(85, Number(tcpSecondary.tolerance || 0))

  const udpAuto = ensureOutbound(
    profile,
    CloudSmartOutboundIds.UdpAuto,
    'Cloud Smart SS UDP Auto',
    Outbound.Urltest,
  )
  syncSubscriptionEntries(udpAuto, subscriptions)
  udpAuto.url = CloudSmartProbeURLSecondary
  udpAuto.include = SmartProtocolInclude.Udp
  udpAuto.exclude = ''
  udpAuto.interval = udpAuto.interval || '2m'
  udpAuto.tolerance = Math.max(100, Number(udpAuto.tolerance || 0))

  const hysteriaAuto = ensureOutbound(
    profile,
    CloudSmartOutboundIds.HysteriaAuto,
    'Cloud Smart Hysteria Backup',
    Outbound.Urltest,
  )
  syncSubscriptionEntries(hysteriaAuto, subscriptions)
  hysteriaAuto.url = CloudSmartProbeURLSecondary
  hysteriaAuto.include = SmartProtocolInclude.Hysteria
  hysteriaAuto.exclude = ''
  hysteriaAuto.interval = hysteriaAuto.interval || '2m'
  hysteriaAuto.tolerance = Math.max(120, Number(hysteriaAuto.tolerance || 0))

  // Smart routing rules
  const udpRuleTemplate: IRule = {
    id: CloudSmartRuleIds.UdpRoute,
    type: RuleType.Network,
    payload: 'udp',
    invert: false,
    action: RuleAction.Route,
    outbound: CloudSmartOutboundIds.UdpAuto,
    sniffer: [],
    strategy: Strategy.Default,
    server: '',
  }

  const tcp443RuleTemplate: IRule = {
    id: CloudSmartRuleIds.Tcp443Route,
    type: RuleType.Port,
    payload: '443',
    invert: false,
    action: RuleAction.Route,
    outbound: CloudSmartOutboundIds.TcpPrimary,
    sniffer: [],
    strategy: Strategy.Default,
    server: '',
  }

  const tcpWebRuleTemplate: IRule = {
    id: CloudSmartRuleIds.TcpWebRoute,
    type: RuleType.Port,
    payload: '80,8080',
    invert: false,
    action: RuleAction.Route,
    outbound: CloudSmartOutboundIds.TcpSecondary,
    sniffer: [],
    strategy: Strategy.Default,
    server: '',
  }

  const managedRules = [
    { ...tcp443RuleTemplate },
    { ...tcpWebRuleTemplate },
    { ...udpRuleTemplate },
  ]
  // Place smart-routing port/UDP rules AFTER the last direct (bypass) rule —
  // otherwise TCP/443 catches everything and CN domain rules (Mainland → direct)
  // never run, sending jd.com / taobao.com etc. through the proxy.
  let insertAfter = -1
  for (let i = profile.route.rules.length - 1; i >= 0; i--) {
    if (profile.route.rules[i].outbound === ProfileDefaults.DefaultOutboundIds.Direct) {
      insertAfter = i
      break
    }
  }
  if (insertAfter >= 0) {
    profile.route.rules.splice(insertAfter + 1, 0, ...managedRules)
  } else {
    profile.route.rules.push(...managedRules)
  }

  // Wire smart auto into fallback
  const defaultFallbackId = ProfileDefaults.DefaultRoute().final
  const autoManagedFinalIds = new Set([
    '',
    defaultFallbackId,
    'outbound-urlte',
    'outbound-select',
    CloudSmartOutboundIds.Auto,
    ...CloudSmartLegacyIds.Outbounds,
  ])
  if (autoManagedFinalIds.has(String(profile.route.final || ''))) {
    profile.route.final = CloudSmartOutboundIds.Auto
  }

  const fallbackOutbound = profile.outbounds.find((item) => item.id === defaultFallbackId)
  if (fallbackOutbound && fallbackOutbound.type === Outbound.Selector) {
    const smartOutboundRefs = [
      { id: CloudSmartOutboundIds.Auto, index: 0 },
      { id: CloudSmartOutboundIds.TcpPrimary, index: 1 },
      { id: CloudSmartOutboundIds.TcpSecondary, index: 2 },
      { id: CloudSmartOutboundIds.UdpAuto, index: 3 },
      { id: CloudSmartOutboundIds.HysteriaAuto, index: 4 },
    ]
    for (const { id, index } of smartOutboundRefs) {
      upsertBuiltInChild(
        fallbackOutbound,
        {
          id,
          type: 'Built-in',
          tag: findOutboundTag(profile, id),
        },
        index,
      )
    }
  }
}
