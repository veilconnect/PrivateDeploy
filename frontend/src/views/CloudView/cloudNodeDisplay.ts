import type { CdnDeployment, CloudNode } from '@/types/cloud'

type TranslateFn = (key: string, params?: Record<string, unknown>) => string
type DisplayCloudNode = CloudNode & { statusText?: string; status?: string }

export type DeploymentStepState = 'done' | 'current' | 'pending'
export type DeploymentStep = { label: string; state: DeploymentStepState }
export type NodeProtocolLink = { label: string; url: string }

const DefaultHysteriaServerName = 'www.bing.com'
const DefaultVlessServerName = 'www.microsoft.com'
const DefaultTrojanServerName = 'www.microsoft.com'

const ensureNode = (node: CloudNode | Record<string, any>): DisplayCloudNode => node as DisplayCloudNode

const resolveServerName = (value: string | undefined, fallback: string) => {
  const trimmed = value?.trim()
  return trimmed || fallback
}

const resolveTLSInsecure = (node: DisplayCloudNode, protocol: 'hysteria' | 'trojan') => {
  const flag = protocol === 'hysteria' ? node.hysteriaInsecure : node.trojanInsecure
  if (typeof flag === 'boolean') {
    return flag
  }
  return false
}

const wrapHostForUri = (host: string): string => {
  if (!host.includes(':')) return host
  return host.startsWith('[') ? host : `[${host}]`
}

const encodeBase64 = (value: string): string => {
  if (typeof btoa === 'function') {
    return btoa(value)
  }
  // @ts-expect-error - Buffer is available in Node contexts and polyfilled in browsers.
  return Buffer.from(value, 'utf-8').toString('base64')
}

export const isPublicIPv4 = (ip?: string): boolean => {
  if (!ip) return false
  const octets = ip.split('.')
  if (octets.length !== 4) return false

  const first = Number.parseInt(octets[0], 10)
  const second = Number.parseInt(octets[1], 10)

  if (first === 100 && second >= 64 && second <= 127) return false
  if (first === 10) return false
  if (first === 192 && second === 168) return false
  if (first === 172 && second >= 16 && second <= 31) return false

  return true
}

const getPreferredAddress = (node: CloudNode | Record<string, any>): string | undefined => {
  const target = ensureNode(node)
  if (target.ipv4 && isPublicIPv4(target.ipv4)) return target.ipv4
  if (target.ipv6) return target.ipv6
  return undefined
}

export const hasShadowsocks = (node: CloudNode | Record<string, any>): boolean => {
  const target = ensureNode(node)
  return Boolean((target.ssPort || target.port) && (target.ssPassword || target.password))
}

export const hasHysteria = (node: CloudNode | Record<string, any>): boolean => {
  const target = ensureNode(node)
  return Boolean(target.hysteriaPort && target.hysteriaPassword)
}

export const hasVless = (node: CloudNode | Record<string, any>): boolean => {
  const target = ensureNode(node)
  return Boolean(target.vlessPort && target.vlessUUID && target.vlessPublicKey && target.vlessShortId)
}

export const hasTrojan = (node: CloudNode | Record<string, any>): boolean => {
  const target = ensureNode(node)
  return Boolean(target.trojanPort && target.trojanPassword)
}

export const hasCdnRelay = (node: CloudNode | Record<string, any>): boolean => {
  const target = ensureNode(node)
  return Boolean(target.vlessRelayPort && target.vlessUUID)
}

const buildShadowsocksLink = (node: CloudNode | Record<string, any>): string | null => {
  const target = ensureNode(node)
  const port = target.ssPort || target.port
  const password = target.ssPassword || target.password
  const host = getPreferredAddress(target)
  if (!port || !password || !host) return null
  const encoded = encodeBase64(`aes-256-gcm:${password}@${wrapHostForUri(host)}:${port}`)
  return `ss://${encoded}#${encodeURIComponent(target.label)}`
}

const buildHysteriaLink = (node: CloudNode | Record<string, any>): string | null => {
  const target = ensureNode(node)
  if (!target.hysteriaPort || !target.hysteriaPassword) return null
  const host = getPreferredAddress(target)
  if (!host) return null

  const query = new URLSearchParams({
    sni: resolveServerName(target.hysteriaServerName, DefaultHysteriaServerName),
  })
  if (resolveTLSInsecure(target, 'hysteria')) {
    query.set('insecure', '1')
  }

  return `hysteria2://${encodeURIComponent(target.hysteriaPassword)}@${wrapHostForUri(host)}:${target.hysteriaPort}?${query.toString()}#${encodeURIComponent(target.label)}`
}

const buildVlessLink = (node: CloudNode | Record<string, any>): string | null => {
  const target = ensureNode(node)
  if (!target.vlessPort || !target.vlessUUID || !target.vlessPublicKey || !target.vlessShortId) return null

  const host = getPreferredAddress(target)
  if (!host) return null

  const query = new URLSearchParams({
    encryption: 'none',
    flow: 'xtls-rprx-vision',
    security: 'reality',
    'reality-public-key': target.vlessPublicKey,
    'reality-short-id': target.vlessShortId,
    sni: resolveServerName(target.vlessServerName, DefaultVlessServerName),
    fp: 'chrome',
  })

  return `vless://${target.vlessUUID}@${wrapHostForUri(host)}:${target.vlessPort}?${query.toString()}#${encodeURIComponent(target.label)}`
}

const buildTrojanLink = (node: CloudNode | Record<string, any>): string | null => {
  const target = ensureNode(node)
  if (!target.trojanPort || !target.trojanPassword) return null

  const host = getPreferredAddress(target)
  if (!host) return null

  const query = new URLSearchParams({
    security: 'tls',
    sni: resolveServerName(target.trojanServerName, DefaultTrojanServerName),
  })
  if (resolveTLSInsecure(target, 'trojan')) {
    query.set('allowInsecure', '1')
    query.set('insecure', '1')
  }

  return `trojan://${encodeURIComponent(target.trojanPassword)}@${wrapHostForUri(host)}:${target.trojanPort}?${query.toString()}#${encodeURIComponent(target.label)}`
}

// buildVlessCdnLink emits a vless+ws+tls share URL pointing at the user's
// Cloudflare Worker host. Mirrors the mobile cloud_node_config_builder.dart
// "<label>-CDN" variant: same UUID, no Reality, ws transport over TLS to the
// Worker on port 443. The Worker forwards encrypted bytes to the VPS plain
// VLESS relay (vlessRelayPort) over raw TCP. Returns null unless both the
// VPS-side relay port AND a deployed Worker host are present.
const buildVlessCdnLink = (
  node: CloudNode | Record<string, any>,
  deployment: CdnDeployment | null | undefined,
): string | null => {
  const target = ensureNode(node)
  if (!deployment) return null
  if (!target.vlessRelayPort || !target.vlessUUID) return null

  // Prefer the M1 Workers Custom Domain only when readiness probe has
  // confirmed it (status === 'active'). Pending/failed → fall back to
  // workers.dev so a freshly-bound link the user shares isn't broken
  // for the recipient. workers.dev is also the only fallback target
  // when no custom domain is wired at all.
  const customReady =
    !!deployment.customHost?.trim() &&
    deployment.customHostStatus === 'active'
  const host = customReady
    ? deployment.customHost!.trim()
    : (deployment.workerHost?.trim() || '')
  if (!host) return null
  const query = new URLSearchParams({
    encryption: 'none',
    security: 'tls',
    type: 'ws',
    sni: host,
    host: host,
    path: '/?ed=2560',
    fp: 'chrome',
  })

  return `vless://${target.vlessUUID}@${host}:443?${query.toString()}#${encodeURIComponent(`${target.label}-CDN`)}`
}

export const buildNodeProtocolLinks = (
  node: CloudNode | Record<string, any>,
  deployment?: CdnDeployment | null,
): NodeProtocolLink[] => {
  const target = ensureNode(node)
  return [
    { label: 'Shadowsocks', url: buildShadowsocksLink(target) },
    { label: 'Hysteria2', url: buildHysteriaLink(target) },
    { label: 'VLESS-Reality', url: buildVlessLink(target) },
    { label: 'Trojan', url: buildTrojanLink(target) },
    { label: 'VLESS-CDN', url: buildVlessCdnLink(target, deployment ?? null) },
  ].filter((item): item is NodeProtocolLink => Boolean(item.url))
}

export const shouldShowDeploymentProgress = (node: CloudNode | Record<string, any>): boolean => {
  const target = ensureNode(node)
  return target.statusText !== 'connected' && target.statusText !== 'error'
}

const computeDeploymentSteps = (
  node: CloudNode | Record<string, any>,
  translate: TranslateFn,
): DeploymentStep[] => {
  const target = ensureNode(node)
  const normalizedStatus = (target.status || '').toString().toLowerCase()
  const instanceReady = ['active', 'running', 'ok', 'started', 'poweron', 'power on', 'power_on'].some((key) =>
    normalizedStatus.includes(key),
  )
  const ipReady = Boolean(isPublicIPv4(target.ipv4) || target.ipv6)
  const protocolsReady = hasShadowsocks(target) || hasHysteria(target) || hasVless(target) || hasTrojan(target)
  const applied = target.statusText === 'connected'

  const rawSteps = [
    { label: translate('cloud.progress.submitted'), done: true },
    { label: translate('cloud.progress.provisioning'), done: instanceReady },
    { label: translate('cloud.progress.waitingIp'), done: ipReady },
    { label: translate('cloud.progress.configuring'), done: protocolsReady },
    { label: translate('cloud.progress.ready'), done: applied },
  ]

  const firstIncomplete = rawSteps.findIndex((step) => !step.done)

  return rawSteps.map((step, index) => {
    const state: DeploymentStepState =
      step.done || firstIncomplete === -1
        ? 'done'
        : index === firstIncomplete
          ? 'current'
          : 'pending'
    return {
      label: step.label,
      state,
    }
  })
}

export const getDeploymentSteps = (
  node: CloudNode | Record<string, any>,
  translate: TranslateFn,
): DeploymentStep[] => computeDeploymentSteps(node, translate)

export const getDeploymentSummary = (
  node: CloudNode | Record<string, any>,
  translate: TranslateFn,
): string => {
  const steps = computeDeploymentSteps(node, translate)
  const total = steps.length
  const currentIndex = steps.findIndex((step) => step.state === 'current')
  const effectiveIndex = currentIndex === -1 ? total - 1 : currentIndex
  const label =
    steps[effectiveIndex]?.label ??
    steps[Math.min(steps.length - 1, Math.max(0, effectiveIndex))]?.label ??
    ''
  const stepNumber = currentIndex === -1 ? total : currentIndex + 1

  return translate('cloud.progress.summary', {
    current: stepNumber,
    total,
    label,
  })
}
