<script setup lang="ts">
import { computed, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'

import { ClipboardSetText } from '@/bridge'
import { useCloudStore, useKernelApiStore } from '@/stores'
import { confirm, formatDate, formatRelativeTime, message } from '@/utils'
import { logError, logInfo } from '@/utils/logger'

import type { CloudNode, CloudPlan, CloudRegion } from '@/types/cloud'

const { t } = useI18n()
const cloudStore = useCloudStore()
const kernelApiStore = useKernelApiStore()

const form = reactive({
  label: defaultLabel(cloudStore.currentProvider),
  region: '',
  plan: '',
})

const loadingMeta = computed(() => cloudStore.loadingPlans || cloudStore.loadingRegions)
const hasApiKey = computed(() => cloudStore.config.apiKey.trim().length > 0)

function formatRegion(region: CloudRegion) {
  // For DigitalOcean, backend already provides bilingual format (e.g., "New York 1 (纽约1)")
  // Just display the city field directly
  if (cloudStore.currentProvider === 'digitalocean') {
    return region.city
  }

  // For other providers (Vultr), use i18n translation
  const cityKey = `cloud.regions.${region.city}`
  const countryKey = `cloud.regions.${region.country}`

  const city = t(cityKey) !== cityKey ? t(cityKey) : region.city
  const country = t(countryKey) !== countryKey ? t(countryKey) : region.country

  return `${city}, ${country}`
}

const providerOptions = computed(() =>
  cloudStore.availableProviders.map((provider) => ({
    label: provider.displayName,
    value: provider.name,
  })),
)

const regionOptions = computed(() =>
  cloudStore.regions.map((region: CloudRegion) => ({
    label: formatRegion(region),
    value: region.id,
  })),
)

type StatusKey = 'unknown' | 'pending' | 'applying' | 'connected' | 'error'

const statusLabels = computed<Record<StatusKey, string>>(() => ({
  unknown: t('cloud.status.unknown'),
  pending: t('cloud.status.pending'),
  applying: t('cloud.status.applying'),
  connected: t('cloud.status.connected'),
  error: t('cloud.status.error'),
}))

type TagColor = 'cyan' | 'green' | 'red' | 'default' | 'primary'
const statusColors: Record<StatusKey, TagColor> = {
  unknown: 'default',
  pending: 'green',
  applying: 'cyan',
  connected: 'primary',
  error: 'red',
}

const getStatusLabel = (status?: string) => statusLabels.value[(status || 'unknown') as StatusKey]
const getStatusColor = (status?: string): TagColor => statusColors[(status || 'unknown') as StatusKey]

const availablePlanIds = computed(() => cloudStore.availability[form.region] || [])

const planOptions = computed(() => {
  const availabilityData = cloudStore.availability
  const currentRegion = form.region

  if (!cloudStore.plans.length) {
    return []
  }

  if (!currentRegion) {
    return cloudStore.plans.map((plan: CloudPlan) => ({
      label: formatPlan(plan),
      value: plan.id,
    }))
  }

  const ids = availabilityData[currentRegion] || []

  if (ids.length > 0) {
    const source = cloudStore.plans.filter((plan: CloudPlan) => ids.includes(plan.id))
    return source.map((plan: CloudPlan) => ({
      label: formatPlan(plan),
      value: plan.id,
    }))
  }

  return cloudStore.plans.map((plan: CloudPlan) => ({
    label: formatPlan(plan),
    value: plan.id,
  }))
})

const regionMap = computed(() => new Map(cloudStore.regions.map((r) => [r.id, formatRegion(r)])))
const planMap = computed(() => {
  const map = new Map()
  for (const p of cloudStore.plans) {
    try {
      map.set(p.id, formatPlan(p))
    } catch (error) {
      console.error('[CloudView] Error formatting plan:', p.id, error)
      // Fallback to plan ID if formatting fails
      map.set(p.id, p.id)
    }
  }
  console.log('[CloudView] planMap updated, size:', map.size, 'plans:', cloudStore.plans.length)
  return map
})

// Function to translate region ID or name in node list
function formatNodeRegion(regionId: string): string {
  // First try to translate as region ID (e.g., "atl" -> "亚特兰大")
  const idKey = `cloud.regions.${regionId}`
  if (t(idKey) !== idKey) {
    return t(idKey)
  }

  // If not found, try regionMap (for formatted region strings)
  const mapped = regionMap.value.get(regionId)
  if (mapped) {
    return mapped
  }

  // Last resort: try to translate as city name
  return t(idKey) !== idKey ? t(idKey) : regionId
}

const tableData = computed(() => {
  // TEMPORARY: Disable provider filtering to debug node list display issue
  const data = cloudStore.instances.map((node) => ({
    ...node,
    id: node.instanceId,
  }))
  return data
})

const applyingNodeId = ref('')
const refreshIntervalId = ref<number | null>(null)

const disableDeploy = computed(
  () => !hasApiKey.value || !form.region || !form.plan || !form.label.trim(),
)

function defaultLabel(provider: string = cloudStore.currentProvider) {
  const safePrefix = provider && provider.trim().length > 0 ? provider : 'node'
  return `${safePrefix}-${Date.now().toString(36)}`
}

function formatPlan(plan: CloudPlan) {
  // Defensive: handle missing or invalid plan data
  if (!plan || typeof plan !== 'object') {
    return String(plan || '')
  }

  const cpuCount = (plan as Record<string, any>).vcpu_count ?? (plan as Record<string, any>).vcpus ?? plan.vcpus ?? 0

  // Defensive: ensure numeric values are valid before formatting
  const ramValue = typeof plan.ram === 'number' && !isNaN(plan.ram) && isFinite(plan.ram) ? plan.ram : 0
  const diskValue = typeof plan.disk === 'number' && !isNaN(plan.disk) && isFinite(plan.disk) ? plan.disk : 0
  const bandwidthValue = typeof plan.bandwidth === 'number' && !isNaN(plan.bandwidth) && isFinite(plan.bandwidth) ? plan.bandwidth : 0

  const ram = ramValue >= 1024 ? `${(ramValue / 1024).toFixed(1)}GB` : `${ramValue}MB`
  const disk = diskValue >= 1024 ? `${(diskValue / 1024).toFixed(1)}TB` : `${diskValue}GB`
  const bandwidth = bandwidthValue >= 1024 ? `${(bandwidthValue / 1024).toFixed(1)}TB` : `${bandwidthValue}GB`

  const meta = [
    `${cpuCount} ${t('cloud.format.vcpu')}`,
    `${ram} ${t('cloud.format.ram')}`,
    `${disk} ${t('cloud.format.disk')}`,
    `${bandwidth} ${t('cloud.format.bandwidth')}`
  ]

  // Add price if available (check both camelCase and snake_case)
  const monthlyCost = plan.monthlyCost || (plan as Record<string, any>).monthly_cost
  if (monthlyCost && monthlyCost > 0 && isFinite(monthlyCost)) {
    meta.push(`$${monthlyCost.toFixed(2)}${t('cloud.format.monthly')}`)
  }

  return plan.description ? `${plan.description} · ${meta.join(' · ')}` : `${plan.id} · ${meta.join(' · ')}`
}

const pickPlanForRegion = (region: string) => {
  const ids = cloudStore.availability[region] || []
  const fallback = ids.find((id) => cloudStore.plans.some((plan) => plan.id === id))
  if (fallback) return fallback
  return cloudStore.plans[0]?.id || ''
}

const ensurePlanForRegion = (region: string) => {
  if (!region) return
  const ids = cloudStore.availability[region]
  if (!ids || ids.length === 0) return
  if (!ids.includes(form.plan)) {
    const replacement = ids.find((id) => cloudStore.plans.some((plan) => plan.id === id)) || ''
    if (replacement) {
      form.plan = replacement
    }
  }
}

const columns = [
  { title: 'cloud.table.label', key: 'label', width: '13%' },
  { title: 'cloud.table.region', key: 'region', width: '10%' },
  { title: 'cloud.table.plan', key: 'plan', width: '13%' },
  { title: 'cloud.table.ipAddresses', key: 'ipAddresses', width: '15%' },
  { title: 'cloud.table.protocols', key: 'protocols', width: '20%' },
  { title: 'cloud.table.status', key: 'status', width: '16%' },
  { title: 'cloud.table.createdAt', key: 'createdAt', width: '10%' },
  { title: 'cloud.table.actions', key: 'actions', width: '11%' },
]

const applyDefaults = async () => {
  console.log('[CloudView] applyDefaults called, form.region:', form.region, 'config.defaultRegion:', cloudStore.config.defaultRegion, 'regions[0]:', cloudStore.regions[0]?.id)

  // Drop stale selections when provider defaults were cleared
  const validRegionIds = new Set(cloudStore.regions.map((region) => region.id))
  if (form.region && !validRegionIds.has(form.region)) {
    form.region = ''
  }
  const validPlanIds = new Set(cloudStore.plans.map((plan) => plan.id))
  if (form.plan && !validPlanIds.has(form.plan)) {
    form.plan = ''
  }

  if (!form.region) {
    const defaultRegion = cloudStore.config.defaultRegion
    const autoPickRegion = defaultRegion || (cloudStore.regions.length === 1 ? cloudStore.regions[0]?.id : '')
    form.region = autoPickRegion || ''
    console.log('[CloudView] Set form.region to:', form.region)
  }
  if (form.region) {
    await cloudStore.ensureRegionAvailability(form.region, true)
    if (!form.plan) {
      form.plan = cloudStore.config.defaultPlan || pickPlanForRegion(form.region)
    } else {
      ensurePlanForRegion(form.region)
    }
  } else if (!form.plan) {
    form.plan = cloudStore.config.defaultPlan || cloudStore.plans[0]?.id || ''
  }
}

watch(
  () => [cloudStore.regions.length, cloudStore.plans.length, cloudStore.config.defaultPlan, cloudStore.config.defaultRegion],
  applyDefaults,
)

watch(
  () => form.region,
  async (value, oldValue) => {
    console.log('[CloudView] Region changed:', oldValue, '->', value)

    // Only save region to config if it's valid for the current provider
    const isValidRegion = value && cloudStore.regions.some(r => r.id === value)
    if (isValidRegion) {
      cloudStore.config.defaultRegion = value
      console.log('[CloudView] Saved valid region to config:', value)
    } else {
      console.log('[CloudView] Skipped saving invalid region:', value)
    }

    if (value && value !== oldValue) {
      console.log('[CloudView] Forcing availability reload for region:', value)
      // 强制重新加载可用性数据
      await cloudStore.ensureRegionAvailability(value, true)
      console.log('[CloudView] Availability loaded:', cloudStore.availability[value])
      ensurePlanForRegion(value)
    }
  },
)

watch(
  () => form.plan,
  (value) => {
    // Only save plan to config if it's valid for the current provider
    const isValidPlan = value && cloudStore.plans.some(p => p.id === value)
    if (isValidPlan) {
      cloudStore.config.defaultPlan = value
    }
  },
)

watch(
  () => cloudStore.currentProvider,
  (provider, previous) => {
    if (!provider || provider === previous) {
      return
    }
    const trimmedLabel = form.label.trim()
    const previousPrefix = previous ? `${previous}-` : 'node-'
    const wasAutoGenerated =
      trimmedLabel.startsWith(previousPrefix) &&
      /^[0-9a-z]+$/i.test(trimmedLabel.slice(previousPrefix.length))

    if (!trimmedLabel || wasAutoGenerated) {
      form.label = defaultLabel(provider)
    }
  },
)

onUnmounted(() => {
  if (refreshIntervalId.value !== null) {
    clearInterval(refreshIntervalId.value)
    refreshIntervalId.value = null
  }
})

onMounted(async () => {
  try {
    // Load available providers and get current provider
    await Promise.allSettled([cloudStore.loadProviders(), cloudStore.getCurrentProvider()])

    await cloudStore.loadConfig()
    if (cloudStore.config.apiKey) {
      // Load regions and plans in parallel
      await Promise.allSettled([cloudStore.fetchRegions(), cloudStore.fetchPlans()])

      // First refresh: use silent mode to avoid blocking UI on slow networks
      cloudStore.refreshInstances(true).catch((e) => {
        logError('[CloudView] Initial refresh failed:', e)
      })

      // Start background refresh (silent, updates every 30 seconds)
      if (refreshIntervalId.value !== null) {
        clearInterval(refreshIntervalId.value)
      }
      refreshIntervalId.value = window.setInterval(() => {
        if (cloudStore.config.apiKey) {
          cloudStore.refreshInstances(true).catch((e) => logError('[CloudView] Background refresh failed:', e))
        }
      }, 30000)
    } else {
      await Promise.allSettled([cloudStore.fetchRegions(), cloudStore.fetchPlans()])
    }
    await applyDefaults()
  } catch (error) {
    logError('[CloudView] onMounted error:', error)
    // Ensure loading state is reset on error
    cloudStore.loadingInstances = false
    handleError(error)
  }
})

const handleError = (error: unknown) => {
  let messageText = error instanceof Error ? error.message : String(error)
  logError('[Cloud Deploy]', error)
  logError('[Cloud Deploy]', messageText)

  // 检测并翻译 Vultr API 错误信息
  const lowerMessage = messageText.toLowerCase()

  // "requires a plan with at least X MB memory"
  const memoryMatch = messageText.match(/at least (\d+)\s*MB memory/i)
  if (memoryMatch) {
    const required = memoryMatch[1]
    messageText = t('cloud.errors.memoryTooLow', { required })
  }
  // "plan is not available in the selected region"
  else if (lowerMessage.includes('plan') && lowerMessage.includes('not available') && lowerMessage.includes('region')) {
    messageText = t('cloud.errors.planUnavailable')
  }
  // "API key" 相关错误
  else if (lowerMessage.includes('api key') || lowerMessage.includes('apikey')) {
    const missingHints = ['missing', 'empty', 'require', 'not configured', 'cannot be empty']
    const invalidHints = ['invalid', 'unauthorized', 'forbidden']
    const isMissingKey = missingHints.some((hint) => lowerMessage.includes(hint))
    const isInvalidKey = invalidHints.some((hint) => lowerMessage.includes(hint))

    if (isMissingKey) {
      messageText = t('cloud.errors.apiKeyRequired')
    } else if (isInvalidKey) {
      messageText = t('cloud.errors.apiKeyInvalid')
    }
  }

  message.error(messageText)
}

const handleProviderChange = async () => {
  try {
    await cloudStore.switchProvider(cloudStore.currentProvider)
    message.success(t('cloud.provider.switched'))

    // Clear form values since region/plan IDs are provider-specific
    form.region = ''
    form.plan = ''
    form.label = defaultLabel(cloudStore.currentProvider)

    // Auto-refresh regions and plans if API key is available
    if (hasApiKey.value) {
      await fetchMeta()
    }

    // Apply defaults for the new provider
    await applyDefaults()
  } catch (error) {
    logError('[CloudView] Failed to switch provider:', error)
    handleError(error)
  }
}

const handleSaveConfig = async () => {
  if (!hasApiKey.value) {
    message.error(t('cloud.errors.apiKeyRequired'))
    return
  }
  try {
    await cloudStore.saveConfig()
    message.success('common.success')
    await fetchMeta()
  } catch (error) {
    handleError(error)
  }
}

const fetchMeta = async () => {
  try {
    await Promise.all([cloudStore.fetchRegions(), cloudStore.fetchPlans()])
    await cloudStore.refreshInstances(true)
    applyDefaults()
  } catch (error) {
    handleError(error)
  }
}

const handleRefreshInstances = async () => {
  if (!hasApiKey.value) {
    message.error(t('cloud.errors.apiKeyRequired'))
    return
  }
  try {
    await cloudStore.refreshInstances()
  } catch (error) {
    handleError(error)
  }
}

const handleDeploy = async () => {
  if (disableDeploy.value) {
    message.error(t('cloud.errors.formIncomplete'))
    return
  }
  try {
    await cloudStore.ensureRegionAvailability(form.region)
    const ids = availablePlanIds.value
    if (ids.length && !ids.includes(form.plan)) {
      ensurePlanForRegion(form.region)
      if (!ids.includes(form.plan)) {
        message.error(t('cloud.errors.planUnavailable'))
        return
      }
    }
    await cloudStore.createInstance({
      label: form.label.trim(),
      region: form.region,
      plan: form.plan,
    })
    message.success('common.success')
    form.label = defaultLabel()
    await cloudStore.refreshInstances()
  } catch (error) {
    handleError(error)
  }
}

const handleUseNode = async (node: CloudNode | Record<string, any>) => {
  const target = node as CloudNode
  cloudStore.markNodeStatus(target.instanceId, 'applying')
  applyingNodeId.value = target.instanceId
  try {
    await cloudStore.applyNodeToProfile(target)
    if (kernelApiStore.running) {
      await kernelApiStore.restartCore()
    } else {
      await kernelApiStore.startCore()
    }
    cloudStore.markNodeStatus(target.instanceId, 'connected')
    // Use silent refresh to avoid showing loading state
    cloudStore.refreshInstances(true).catch((e) => logError('[CloudView] Silent refresh after apply failed:', e))
    message.success(t('cloud.nodes.applied'))
    message.info(t('cloud.nodes.applyTip'))
  } catch (error) {
    cloudStore.markNodeStatus(target.instanceId, 'error')
    handleError(error)
  } finally {
    applyingNodeId.value = ''
  }
}

const isPublicIPv4 = (ip?: string): boolean => {
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

const copyValue = async (value: string) => {
  if (!value) return
  try {
    await ClipboardSetText(value)
    message.success('common.copied')
  } catch (error) {
    handleError(error)
  }
}

type DisplayCloudNode = CloudNode & { statusText?: string; status?: string }

const ensureNode = (node: CloudNode | Record<string, any>): DisplayCloudNode => node as DisplayCloudNode

const getPreferredAddress = (node: CloudNode | Record<string, any>): string | undefined => {
  const target = ensureNode(node)
  if (target.ipv4 && isPublicIPv4(target.ipv4)) return target.ipv4
  if (target.ipv6) return target.ipv6
  return undefined
}

const wrapHostForUri = (host: string): string => {
  if (!host.includes(':')) return host
  return host.startsWith('[') ? host : `[${host}]`
}

const buildShadowsocksLink = (node: CloudNode | Record<string, any>): string | null => {
  const target = ensureNode(node)
  const port = target.ssPort || target.port
  const password = target.ssPassword || target.password
  const host = getPreferredAddress(target)
  if (!port || !password || !host) return null
  const encoded = btoa(`aes-256-gcm:${password}@${wrapHostForUri(host)}:${port}`)
  return `ss://${encoded}#${encodeURIComponent(target.label)}`
}

const buildHysteriaLink = (node: CloudNode | Record<string, any>): string | null => {
  const target = ensureNode(node)
  if (!target.hysteriaPort || !target.hysteriaPassword) return null
  const host = getPreferredAddress(target)
  if (!host) return null
  const query = new URLSearchParams({ sni: 'www.bing.com', insecure: '1' })
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
    sni: 'www.microsoft.com',
    fp: 'chrome',
  })
  return `vless://${target.vlessUUID}@${wrapHostForUri(host)}:${target.vlessPort}?${query.toString()}#${encodeURIComponent(target.label)}`
}

const buildTrojanLink = (node: CloudNode | Record<string, any>): string | null => {
  const target = ensureNode(node)
  if (!target.trojanPort || !target.trojanPassword) return null
  const host = getPreferredAddress(target)
  if (!host) return null
  const query = new URLSearchParams({ security: 'tls', sni: 'www.microsoft.com', allowInsecure: '1' })
  return `trojan://${encodeURIComponent(target.trojanPassword)}@${wrapHostForUri(host)}:${target.trojanPort}?${query.toString()}#${encodeURIComponent(target.label)}`
}

const hasShadowsocks = (node: CloudNode | Record<string, any>): boolean => {
  const target = ensureNode(node)
  return Boolean((target.ssPort || target.port) && (target.ssPassword || target.password))
}
const hasHysteria = (node: CloudNode | Record<string, any>): boolean => {
  const target = ensureNode(node)
  return Boolean(target.hysteriaPort && target.hysteriaPassword)
}
const hasVless = (node: CloudNode | Record<string, any>): boolean => {
  const target = ensureNode(node)
  return Boolean(target.vlessPort && target.vlessUUID && target.vlessPublicKey && target.vlessShortId)
}
const hasTrojan = (node: CloudNode | Record<string, any>): boolean => {
  const target = ensureNode(node)
  return Boolean(target.trojanPort && target.trojanPassword)
}

type DeploymentStepState = 'done' | 'current' | 'pending'
type DeploymentStep = { label: string; state: DeploymentStepState }

const shouldShowDeploymentProgress = (node: CloudNode | Record<string, any>): boolean => {
  const target = ensureNode(node)
  return target.statusText !== 'connected' && target.statusText !== 'error'
}

const computeDeploymentSteps = (node: CloudNode | Record<string, any>): DeploymentStep[] => {
  const target = ensureNode(node)
  const normalizedStatus = (target.status || '').toString().toLowerCase()
  const instanceReady = ['active', 'running', 'ok', 'started', 'poweron', 'power on', 'power_on'].some((key) =>
    normalizedStatus.includes(key),
  )
  const ipReady = Boolean(isPublicIPv4(target.ipv4) || target.ipv6)
  const protocolsReady = hasShadowsocks(target) || hasHysteria(target) || hasVless(target) || hasTrojan(target)
  const applied = target.statusText === 'connected'

  const rawSteps = [
    { label: t('cloud.progress.submitted'), done: true },
    { label: t('cloud.progress.provisioning'), done: instanceReady },
    { label: t('cloud.progress.waitingIp'), done: ipReady },
    { label: t('cloud.progress.configuring'), done: protocolsReady },
    { label: t('cloud.progress.ready'), done: applied },
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

const getDeploymentSteps = (node: CloudNode | Record<string, any>): DeploymentStep[] => computeDeploymentSteps(node)

const getDeploymentSummary = (node: CloudNode | Record<string, any>): string => {
  const steps = computeDeploymentSteps(node)
  const total = steps.length
  const currentIndex = steps.findIndex((step) => step.state === 'current')
  const effectiveIndex = currentIndex === -1 ? total - 1 : currentIndex
  const label: string =
    steps[effectiveIndex]?.label ??
    steps[Math.min(steps.length - 1, Math.max(0, effectiveIndex))]?.label ??
    ''
  const stepNumber = currentIndex === -1 ? total : currentIndex + 1
  return t('cloud.progress.summary', {
    current: stepNumber,
    total,
    label,
  })
}

const copyProtocolLink = async (link: string | null) => {
  if (!link) {
    message.error(t('cloud.errors.protocolUnavailable'))
    return
  }
  await copyValue(link)
}

const copyShadowsocksLink = async (node: CloudNode | Record<string, any>) => {
  await copyProtocolLink(buildShadowsocksLink(node))
}

const copyHysteriaLink = async (node: CloudNode | Record<string, any>) => {
  await copyProtocolLink(buildHysteriaLink(node))
}

const copyVlessLink = async (node: CloudNode | Record<string, any>) => {
  await copyProtocolLink(buildVlessLink(node))
}

const copyTrojanLink = async (node: CloudNode | Record<string, any>) => {
  await copyProtocolLink(buildTrojanLink(node))
}

const copyNodeConfig = async (record: CloudNode | Record<string, any>) => {
  const node = ensureNode(record)
  const links = [
    { label: 'Shadowsocks', url: buildShadowsocksLink(node) },
    { label: 'Hysteria2', url: buildHysteriaLink(node) },
    { label: 'VLESS-Reality', url: buildVlessLink(node) },
    { label: 'Trojan', url: buildTrojanLink(node) },
  ].filter((item) => item.url) as Array<{ label: string; url: string }>

  if (!links.length) {
    message.error(t('cloud.errors.noProtocols'))
    return
  }

  const payload = links.map((item) => `${item.label}: ${item.url}`).join('\n')
  await copyValue(payload)
}

const handleDestroy = async (record: CloudNode | Record<string, any>) => {
  const node = record as CloudNode
  try {
    await confirm('common.warning', t('cloud.confirmDestroy', { label: node.label }))
  } catch (error) {
    return
  }
  try {
    await cloudStore.destroyInstance(node.instanceId)
    message.success('common.success')
  } catch (error) {
    handleError(error)
  }
}
</script>

<template>
  <div class="cloud-view grid gap-16">
    <Card :title="t('cloud.credentials.title')">
      <div class="flex flex-col gap-12 py-8">
        <div class="flex flex-wrap items-center gap-8">
          <span id="cloud-provider-label" class="text-14 shrink-0">{{ t('cloud.provider.label') }}:</span>
          <Select
            v-model="cloudStore.currentProvider"
            :options="providerOptions"
            @change="handleProviderChange"
            size="small"
            auto-size
            aria-labelledby="cloud-provider-label"
          />
          <Input
            v-model="cloudStore.config.apiKey"
            type="password"
            :show-password="true"
            :auto-size="true"
            :placeholder="t('cloud.credentials.placeholder')"
            class="flex-1 min-w-240"
            aria-label="API Key"
          />
          <Button
            @click="handleSaveConfig"
            type="primary"
            :loading="cloudStore.savingConfig"
            :disabled="!hasApiKey"
          >
            {{ t('cloud.credentials.save') }}
          </Button>
          <Button
            @click="fetchMeta"
            :loading="loadingMeta"
            :disabled="!hasApiKey"
            type="link"
          >
            {{ t('cloud.credentials.syncMeta') }}
          </Button>
        </div>
        <div class="text-12 text-secondary">
          {{ t('cloud.credentials.hint') }}
        </div>
      </div>
    </Card>

    <Card :title="t('cloud.create.title')">
      <div class="flex flex-col gap-12 py-8">
        <div class="flex flex-wrap items-center gap-8">
          <Select
            v-model="form.region"
            :options="regionOptions"
            :placeholder="t('cloud.create.regionPlaceholder')"
            auto-size
            :disabled="!regionOptions.length"
          />
          <Select
            v-model="form.plan"
            :options="planOptions"
            :placeholder="t('cloud.create.planPlaceholder')"
            auto-size
            :disabled="!planOptions.length"
          />
          <Input
            v-model="form.label"
            :auto-size="true"
            :placeholder="t('cloud.create.labelPlaceholder')"
            class="flex-1 min-w-200"
          />
        </div>
        <div class="flex items-center gap-8">
          <Button
            @click="handleDeploy"
            type="primary"
            :loading="cloudStore.creatingInstance"
            :disabled="disableDeploy"
          >
            {{ t('cloud.create.deploy') }}
          </Button>
          <Button
            @click="handleRefreshInstances"
            type="link"
            :loading="cloudStore.loadingInstances"
            :disabled="!hasApiKey"
          >
            {{ t('cloud.create.refresh') }}
          </Button>
        </div>
      </div>
    </Card>

    <Card :title="t('cloud.nodes.title')">
      <div v-if="cloudStore.loadingInstances" class="py-32 text-center text-14">
        {{ t('cloud.nodes.loading') }}
      </div>
      <div v-else-if="!tableData.length" class="py-32">
        <Empty>
          <template #description>{{ t('cloud.nodes.empty') }}</template>
        </Empty>
      </div>
      <div v-else class="py-8">
        <Table :columns="columns" :data-source="tableData">
          <template #region="{ record }">
            <div>{{ formatNodeRegion(record.region) }}</div>
          </template>
          <template #plan="{ record }">
            <div>{{ planMap.get(record.plan) || record.plan }}</div>
          </template>
          <template #status="{ record }">
            <div class="flex flex-col gap-2">
              <div class="flex items-center gap-4">
                <span class="capitalize">{{ record.status }}</span>
                <Tag :color="getStatusColor(record.statusText)" size="small">
                  {{ getStatusLabel(record.statusText) }}
                </Tag>
              </div>
              <div v-if="shouldShowDeploymentProgress(record)" class="deployment-progress">
                <div class="deployment-progress__summary">
                  {{ getDeploymentSummary(record) }}
                </div>
                <div class="deployment-progress__steps">
                  <div
                    v-for="(step, index) in getDeploymentSteps(record)"
                    :key="index"
                    class="deployment-progress__step"
                    :class="`deployment-progress__step--${step.state}`"
                  >
                    <span class="deployment-progress__bullet" />
                    <span class="deployment-progress__label">{{ step.label }}</span>
                  </div>
                </div>
              </div>
            </div>
          </template>
          <template #ipAddresses="{ record }">
            <div class="flex flex-col gap-2">
              <div v-if="isPublicIPv4(record.ipv4)" class="flex items-center gap-2" style="font-size: 11px">
                <Tag size="small" color="cyan">v4</Tag>
                <span class="font-mono" style="max-width: 120px; overflow: hidden; text-overflow: ellipsis" :title="record.ipv4">{{ record.ipv4 }}</span>
              </div>
              <div v-if="record.ipv6" class="flex items-center gap-2" style="font-size: 11px">
                <Tag size="small" color="green">v6</Tag>
                <span class="font-mono" style="max-width: 120px; overflow: hidden; text-overflow: ellipsis" :title="record.ipv6">{{ record.ipv6 }}</span>
              </div>
              <div v-if="!isPublicIPv4(record.ipv4) && !record.ipv6">
                <span class="text-secondary">-</span>
              </div>
            </div>
          </template>
          <template #protocols="{ record }">
            <div class="protocol-list">
              <div v-if="hasShadowsocks(record)" class="protocol-item">
                <Tag size="small" color="primary">SS</Tag>
                <span class="protocol-meta">:{{ record.ssPort || record.port }}</span>
              </div>

              <div v-if="hasHysteria(record)" class="protocol-item">
                <Tag size="small" color="cyan">HY2</Tag>
                <span class="protocol-meta">:{{ record.hysteriaPort }}</span>
              </div>

              <div v-if="hasVless(record)" class="protocol-item">
                <Tag size="small" color="green">VLESS</Tag>
                <span class="protocol-meta">:{{ record.vlessPort }}</span>
              </div>

              <div v-if="hasTrojan(record)" class="protocol-item">
                <Tag size="small" color="red">Trojan</Tag>
                <span class="protocol-meta">:{{ record.trojanPort }}</span>
              </div>

              <div v-if="!hasShadowsocks(record) && !hasHysteria(record) && !hasVless(record) && !hasTrojan(record)" class="text-secondary">
                -
              </div>
            </div>
          </template>
          <template #createdAt="{ record }">
            <div class="flex flex-col" style="font-size: 11px">
              <span>{{ formatDate(record.createdAt, 'YYYY-MM-DD') }}</span>
              <span class="text-secondary">{{ formatRelativeTime(record.createdAt) }}</span>
            </div>
          </template>
          <template #actions="{ record }">
            <div class="flex items-center gap-4">
              <Button
                @click="handleUseNode(record)"
                type="primary"
                size="small"
                :loading="applyingNodeId === record.instanceId"
              >
                {{ t('cloud.nodes.apply') }}
              </Button>
              <Button @click="copyNodeConfig(record)" type="text" size="small" v-tips="'cloud.nodes.copyLink'">📋</Button>
              <Button
                @click="handleDestroy(record)"
                type="text"
                size="small"
                :loading="cloudStore.destroyingInstance === record.instanceId"
              >
                {{ t('cloud.nodes.destroy') }}
              </Button>
            </div>
          </template>
        </Table>
      </div>
    </Card>
  </div>
</template>

<style lang="less" scoped>
.cloud-view {
  padding: 16px;
}

.text-secondary {
  color: var(--text-secondary-color);
}

.min-w-200 {
  min-width: 200px;
}

.min-w-240 {
  min-width: 240px;
}

.protocol-list {
  display: flex;
  flex-direction: row;
  flex-wrap: wrap;
  gap: 4px;
}

.protocol-item {
  display: flex;
  align-items: center;
  gap: 2px;
  font-size: 11px;
}

.protocol-header {
  display: flex;
  align-items: center;
  gap: 2px;
}

.protocol-meta {
  display: inline-flex;
  align-items: center;
  font-family: var(--font-family-mono, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New', monospace);
  font-size: 10px;
  line-height: 1.2;

  span {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 60px;
  }
}

.deployment-progress {
  font-size: 11px;
  color: var(--text-secondary-color);
}

.deployment-progress__summary {
  font-weight: 600;
}

.deployment-progress__steps {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.deployment-progress__step {
  display: flex;
  align-items: center;
  gap: 6px;
}

.deployment-progress__bullet {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--divider-color);
  flex-shrink: 0;
}

.deployment-progress__step--done .deployment-progress__bullet {
  background: var(--success-color);
}

.deployment-progress__step--current .deployment-progress__bullet {
  background: var(--primary-color);
  box-shadow: 0 0 0 2px color-mix(in srgb, var(--primary-color) 20%, transparent);
}

.deployment-progress__step--pending .deployment-progress__label {
  opacity: 0.7;
}

.deployment-progress__label {
  flex: 1;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
</style>
