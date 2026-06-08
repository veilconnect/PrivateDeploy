import { deepClone } from '@/utils'

import type { CoreApiProxy } from '@/types/kernel'

type CoreApiProxyMap = Record<string, CoreApiProxy>

type CloudNodeLike = {
  label: string
  ipv4?: string
  ipv6?: string
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
}

const isPublicIPv4 = (ip?: string): boolean => {
  if (!ip) return false

  const parts = ip.split('.').map(Number)
  if (parts[0] === 10) return false
  if (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) return false
  if (parts[0] === 192 && parts[1] === 168) return false
  if (parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127) return false
  return true
}

export const removeProxyFromKernelGroups = (
  proxies: CoreApiProxyMap,
  subscriptionId: string,
): CoreApiProxyMap => {
  const updated = deepClone(proxies)

  Object.keys(updated).forEach((groupName) => {
    const group = updated[groupName]
    if (group.all && Array.isArray(group.all)) {
      group.all = group.all.filter((proxyName) => proxyName !== subscriptionId)

      if (group.now === subscriptionId && group.all.length > 0) {
        group.now = group.all[0]
      }
    }
  })

  delete updated[subscriptionId]
  return updated
}

export const addProxyToKernelGroups = (
  proxies: CoreApiProxyMap,
  subscriptionId: string,
): CoreApiProxyMap => {
  const updated = deepClone(proxies)

  updated[subscriptionId] = {
    name: subscriptionId,
    type: 'Subscription',
    now: '',
    all: [],
    history: [],
    alive: false,
    udp: false,
  }

  Object.keys(updated).forEach((groupName) => {
    const group = updated[groupName]
    if ((group.type === 'Selector' || group.type === 'URLTest') && group.all && Array.isArray(group.all)) {
      if (!group.all.includes(subscriptionId)) {
        group.all = [...group.all, subscriptionId]
      }
    }
  })

  return updated
}

export const addCloudNodeToKernelGroups = (
  proxies: CoreApiProxyMap,
  node: CloudNodeLike,
): CoreApiProxyMap => {
  const updated = deepClone(proxies)
  const proxyTags: string[] = []
  const hasIPv4 = isPublicIPv4(node.ipv4)
  const hasIPv6 = !!node.ipv6
  const ipVersions: string[] = []

  if (hasIPv4) ipVersions.push('-v4')
  if (hasIPv6) ipVersions.push('-v6')

  if (ipVersions.length === 0) {
    console.warn(`[KernelApi] Node ${node.label} has no usable public IP, skipping`)
    return updated
  }

  if (node.ssPort && node.ssPassword) {
    ipVersions.forEach((suffix) => {
      proxyTags.push(`${node.label}-ss${suffix}`)
    })
  }

  if (node.hysteriaPort && node.hysteriaPassword) {
    ipVersions.forEach((suffix) => {
      proxyTags.push(`${node.label}-hysteria2${suffix}`)
    })
  }

  if (node.vlessPort && node.vlessUUID && node.vlessPublicKey && node.vlessShortId) {
    ipVersions.forEach((suffix) => {
      proxyTags.push(`${node.label}-vless${suffix}`)
    })
  }

  if (node.trojanPort && node.trojanPassword) {
    ipVersions.forEach((suffix) => {
      proxyTags.push(`${node.label}-trojan${suffix}`)
    })
  }

  console.log(`[KernelApi] Adding ${proxyTags.length} proxy nodes for ${node.label}:`, proxyTags)

  proxyTags.forEach((tag) => {
    updated[tag] = {
      name: tag,
      type: 'Proxy',
      now: '',
      all: [],
      history: [],
      alive: false,
      udp: false,
    }
  })

  Object.keys(updated).forEach((groupName) => {
    const group = updated[groupName]
    if ((group.type === 'Selector' || group.type === 'URLTest') && group.all && Array.isArray(group.all)) {
      const newTags = proxyTags.filter((tag) => !group.all.includes(tag))
      if (newTags.length > 0) {
        group.all = [...group.all, ...newTags]
      }
    }
  })

  return updated
}
