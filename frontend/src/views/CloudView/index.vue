<script setup lang="ts">
import { computed, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'

import { ClipboardSetText, TestAllCloudRegions } from '@/bridge'
import { useCloudStore, useKernelApiStore } from '@/stores'
import { confirm, formatDate, formatRelativeTime, message, debounce } from '@/utils'
import { logError, logInfo } from '@/utils/logger'
import { getRecommendedNodes } from '@/utils/recommendation'
import { createBackup, parseBackup, downloadBackup } from '@/utils/backup'
import { checkAllNodesHealth, scheduleHealthChecks, getHealthSummary } from '@/utils/healthCheck'
import { isOnline, initOfflineMode } from '@/utils/offline'
import { generateMockConnectivityHistory, type ConnectivityDataPoint, type LatencyDataPoint } from '@/utils/visualization'

import { useModal } from '@/components/Modal'
import ConnectivityChart from '@/components/ConnectivityChart.vue'
import LatencyChart from '@/components/LatencyChart.vue'

import ImportNodesModal from './components/ImportNodesModal.vue'
import ManualNodeModal from './components/ManualNodeModal.vue'

import type { ManualNodeSkipEntry, ManagedCloudNode } from '@/stores/cloud'
import type { CloudNode, CloudPlan, CloudRegion, RegionLatency } from '@/types/cloud'

const { t } = useI18n()
const cloudStore = useCloudStore()
const kernelApiStore = useKernelApiStore()
const [Modal, modalApi] = useModal({
  minWidth: '52',
  maskClosable: true,
})

type ManualNodeInput = Parameters<typeof cloudStore.addManualNode>[0]

const form = reactive({
  label: defaultLabel(cloudStore.currentProvider),
  region: '',
  plan: '',
})

const manualForm = reactive({
  label: '',
  ipv4: '',
  ipv6: '',
  ssPort: '',
  ssPassword: '',
  hysteriaPort: '',
  hysteriaPassword: '',
  vlessPort: '',
  vlessUUID: '',
  vlessPublicKey: '',
  vlessShortId: '',
  trojanPort: '',
  trojanPassword: '',
})

const importForm = reactive({
  raw: '',
})

const loadingMeta = computed(() => cloudStore.loadingPlans || cloudStore.loadingRegions)
const hasApiKey = computed(() => cloudStore.config.apiKey.trim().length > 0)

// Latency testing state
const testingLatency = ref(false)
const latencyResults = ref<RegionLatency[]>([])
const showLatencyResults = ref(false)

// Batch operations state
const selectedNodeIds = ref<Set<string>>(new Set())
const batchOperating = ref(false)

// Visualization state
const viewingChartNode = ref<ManagedCloudNode | null>(null)
const showChartsModal = ref(false)

// Search and filter state
const searchQuery = ref('')
const filterConnectivity = ref<string>('all')
const filterStatus = ref<string>('all')
const sortBy = ref<string>('')
const sortOrder = ref<'asc' | 'desc'>('asc')

// Keyboard shortcuts help
const showKeyboardHelp = ref(false)

// Reachability Risk Rating for regions
// Low: Generally stable, less likely to be blocked
// Medium: Occasional blocking, moderate risk
// High: Frequently targeted, higher risk
// Critical: High blocking risk, unstable
const reachabilityRiskRating: Record<string, 'low' | 'medium' | 'high' | 'critical'> = {
  // Low Risk - Generally stable
  'sgp': 'low',        // Singapore
  'nrt': 'low',        // Tokyo
  'icn': 'low',        // Seoul
  'hkg': 'medium',     // Hong Kong (升级为medium due to recent events)
  'tpe': 'low',        // Taipei
  'bom': 'low',        // Mumbai
  'syd': 'low',        // Sydney

  // Medium Risk - Occasionally targeted
  'lax': 'medium',     // Los Angeles
  'sjc': 'medium',     // San Jose
  'sea': 'medium',     // Seattle
  'ams': 'medium',     // Amsterdam
  'fra': 'medium',     // Frankfurt
  'lhr': 'medium',     // London

  // High Risk - Frequently blocked
  'ewr': 'high',       // New York
  'ord': 'high',       // Chicago
  'dfw': 'high',       // Dallas
  'mia': 'high',       // Miami
  'atl': 'high',       // Atlanta
  'yto': 'high',       // Toronto
  'cdg': 'high',       // Paris

  // Critical Risk - Very unstable
  'default': 'medium'  // Default for unknown regions
}

const getRiskLevel = (regionId: string): 'low' | 'medium' | 'high' | 'critical' => {
  return reachabilityRiskRating[regionId] || reachabilityRiskRating['default']
}

const getRiskIcon = (risk: 'low' | 'medium' | 'high' | 'critical'): string => {
  const iconMap = {
    low: '🟢',
    medium: '🟡',
    high: '🟠',
    critical: '🔴'
  }
  return iconMap[risk]
}

const getRiskLabel = (risk: 'low' | 'medium' | 'high' | 'critical'): string => {
  const keyMap = {
    low: 'cloud.reachabilityRisk.low',
    medium: 'cloud.reachabilityRisk.medium',
    high: 'cloud.reachabilityRisk.high',
    critical: 'cloud.reachabilityRisk.critical'
  }
  return t(keyMap[risk])
}

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

const regionOptions = computed(() => {
  // Create a map of region code to latency
  const latencyMap = new Map<string, RegionLatency>()
  latencyResults.value.forEach((result) => {
    latencyMap.set(result.code, result)
  })

  // Map regions with latency and risk info
  const regionsWithInfo = cloudStore.regions.map((region: CloudRegion) => {
    const latency = latencyMap.get(region.id)
    const regionLabel = formatRegion(region)
    const riskLevel = getRiskLevel(region.id)
    const riskIcon = getRiskIcon(riskLevel)

    // Format label with risk icon and latency if available
    let label = `${riskIcon} ${regionLabel}`
    if (latency) {
      if (latency.status === 'ok') {
        label = `${riskIcon} ${regionLabel} · ${latency.latency.toFixed(0)}ms`
      } else {
        label = `${riskIcon} ${regionLabel} · ${t('cloud.latency.timeout')}`
      }
    }

    return {
      label,
      value: region.id,
      latency: latency?.latency || 9999,
      status: latency?.status || 'unknown',
      riskLevel,
    }
  })

  // Sort by risk level first (low risk first), then by latency
  return regionsWithInfo.sort((a, b) => {
    const riskOrder = { low: 0, medium: 1, high: 2, critical: 3 }
    const riskDiff = riskOrder[a.riskLevel] - riskOrder[b.riskLevel]
    if (riskDiff !== 0) return riskDiff

    // Within same risk level, sort by latency
    if (a.status === 'timeout' && b.status !== 'timeout') return 1
    if (a.status !== 'timeout' && b.status === 'timeout') return -1
    return a.latency - b.latency
  })
})

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

const getConnectivityLabel = (status?: string) => {
  const key = `cloud.connectivity.${status || 'unknown'}`
  return t(key)
}

const getConnectivityColor = (status?: string): TagColor => {
  const colorMap: Record<string, TagColor> = {
    reachable: 'green',
    icmp_blocked: 'cyan',
    blocked: 'red',
    testing: 'default',
    unknown: 'default',
  }
  return colorMap[status || 'unknown'] || 'default'
}

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

const resetManualForm = () => {
  manualForm.label = ''
  manualForm.ipv4 = ''
  manualForm.ipv6 = ''
  manualForm.ssPort = ''
  manualForm.ssPassword = ''
  manualForm.hysteriaPort = ''
  manualForm.hysteriaPassword = ''
  manualForm.vlessPort = ''
  manualForm.vlessUUID = ''
  manualForm.vlessPublicKey = ''
  manualForm.vlessShortId = ''
  manualForm.trojanPort = ''
  manualForm.trojanPassword = ''
}

const resetImportForm = () => {
  importForm.raw = ''
}

const toOptionalNumber = (value: string) => {
  if (!value) return undefined
  const num = Number(value)
  if (!Number.isFinite(num)) return undefined
  const port = Math.trunc(num)
  if (port <= 0 || port > 65535) return undefined
  return port
}

const isManualNode = (node: CloudNode | Record<string, any>) => (node as any).provider === 'manual'

const manualEditingId = ref('')

const mapManualError = (error: unknown) => {
  const messageText = error instanceof Error ? error.message : String(error)
  if (messageText === 'label-required') {
    return t('cloud.errors.manualLabelRequired')
  }
  if (messageText === 'address-required') {
    return t('cloud.errors.manualAddressRequired')
  }
  if (messageText === 'protocol-required') {
    return t('cloud.errors.manualProtocolRequired')
  }
  if (messageText === 'duplicate') {
    return t('cloud.errors.manualDuplicate')
  }
  if (messageText === 'manual-node-not-found') {
    return t('cloud.errors.importInvalid')
  }
  return messageText
}

const formatSkippedImportEntry = (entry: ManualNodeSkipEntry) => {
  if (entry.reason === 'ipv4') {
    return t('cloud.manual.importSkippedIpv4', { value: entry.identifier })
  }
  if (entry.reason === 'ipv6') {
    return t('cloud.manual.importSkippedIpv6', { value: entry.identifier })
  }
  return t('cloud.manual.importSkippedLabel', { value: entry.identifier })
}

const getManualInputFromForm = (): ManualNodeInput => {
  const label = manualForm.label.trim()
  if (!label) {
    throw new Error('label-required')
  }
  const ipv4 = manualForm.ipv4.trim()
  const ipv6 = manualForm.ipv6.trim()
  if (!ipv4 && !ipv6) {
    throw new Error('address-required')
  }
  const input: ManualNodeInput = {
    label,
    ipv4: ipv4 || undefined,
    ipv6: ipv6 || undefined,
    ssPort: toOptionalNumber(manualForm.ssPort) ?? undefined,
    ssPassword: manualForm.ssPassword.trim() || undefined,
    hysteriaPort: toOptionalNumber(manualForm.hysteriaPort) ?? undefined,
    hysteriaPassword: manualForm.hysteriaPassword.trim() || undefined,
    vlessPort: toOptionalNumber(manualForm.vlessPort) ?? undefined,
    vlessUUID: manualForm.vlessUUID.trim() || undefined,
    vlessPublicKey: manualForm.vlessPublicKey.trim() || undefined,
    vlessShortId: manualForm.vlessShortId.trim() || undefined,
    trojanPort: toOptionalNumber(manualForm.trojanPort) ?? undefined,
    trojanPassword: manualForm.trojanPassword.trim() || undefined,
  }

  const hasProtocol =
    (input.ssPort && input.ssPassword) ||
    (input.hysteriaPort && input.hysteriaPassword) ||
    (input.vlessPort && input.vlessUUID && input.vlessPublicKey) ||
    (input.trojanPort && input.trojanPassword)

  if (!hasProtocol) {
    throw new Error('protocol-required')
  }

  return input
}

const handleManualSubmit = async () => {
  try {
    const input = getManualInputFromForm()
    const node = await cloudStore.addManualNode(input)
    await cloudStore.applyNodeToProfile(node)
    message.success(t('cloud.manual.addSuccess'))
    return true
  } catch (error) {
    message.error(mapManualError(error))
    return false
  }
}

const handleManualUpdate = async () => {
  const id = manualEditingId.value
  if (!id) {
    return false
  }
  try {
    const input = getManualInputFromForm()
    const node = await cloudStore.updateManualNode(id, input)
    await cloudStore.applyNodeToProfile(node)
    message.success(t('cloud.manual.updateSuccess'))
    return true
  } catch (error) {
    message.error(mapManualError(error))
    return false
  }
}

const populateManualFormFromNode = (node: Record<string, any>) => {
  manualForm.label = node.label || ''
  manualForm.ipv4 = node.ipv4 || ''
  manualForm.ipv6 = node.ipv6 || ''
  manualForm.ssPort = node.ssPort ? String(node.ssPort) : node.port ? String(node.port) : ''
  manualForm.ssPassword = node.ssPassword || node.password || ''
  manualForm.hysteriaPort = node.hysteriaPort ? String(node.hysteriaPort) : ''
  manualForm.hysteriaPassword = node.hysteriaPassword || ''
  manualForm.vlessPort = node.vlessPort ? String(node.vlessPort) : ''
  manualForm.vlessUUID = node.vlessUUID || ''
  manualForm.vlessPublicKey = node.vlessPublicKey || ''
  manualForm.vlessShortId = node.vlessShortId || ''
  manualForm.trojanPort = node.trojanPort ? String(node.trojanPort) : ''
  manualForm.trojanPassword = node.trojanPassword || ''
}

const decodeBase64 = (value: string): string => {
  try {
    const normalized = value.replace(/-/g, '+').replace(/_/g, '/')
    const padded = normalized + '='.repeat((4 - normalized.length % 4) % 4)
    if (typeof atob === 'function') {
      return atob(padded)
    }
    // @ts-expect-error - Buffer is available in Node contexts (build time) and polyfilled in browsers
    return Buffer.from(padded, 'base64').toString('utf-8')
  } catch {
    return ''
  }
}

const normalizeHost = (host: string) => host.replace(/^\[/, '').replace(/\]$/, '')

const assignIpFields = (host: string): Pick<ManualNodeInput, 'ipv4' | 'ipv6'> => {
  const normalized = normalizeHost(host)
  if (!normalized) {
    return {}
  }
  if (normalized.includes(':')) {
    return { ipv6: normalized }
  }
  return { ipv4: normalized }
}

const parseShadowSocksUrl = (text: string): ManualNodeInput | null => {
  let payload = text.slice('ss://'.length)
  let label = ''
  const hashIndex = payload.indexOf('#')
  if (hashIndex >= 0) {
    label = decodeURIComponent(payload.slice(hashIndex + 1))
    payload = payload.slice(0, hashIndex)
  }
  const queryIndex = payload.indexOf('?')
  if (queryIndex >= 0) {
    payload = payload.slice(0, queryIndex)
  }
  const decoded = decodeBase64(payload)
  if (!decoded || !decoded.includes('@')) {
    return null
  }
  const [methodPart, hostPart] = decoded.split('@')
  if (!hostPart) {
    return null
  }
  const [method, password] = methodPart.split(':')
  const [host, portStr] = hostPart.split(':')
  const port = toOptionalNumber(portStr || '')
  if (!method || !password || !host || !port) {
    return null
  }
  const ipFields = assignIpFields(host)
  const resolvedLabel = label || host
  return {
    label: resolvedLabel,
    ...ipFields,
    ssPort: port,
    ssPassword: password,
  }
}

const parseTrojanUrl = (text: string): ManualNodeInput | null => {
  try {
    const url = new URL(text)
    const host = url.hostname
    const port = toOptionalNumber(url.port || '')
    if (!host || !port) {
      return null
    }
    const label = url.hash ? decodeURIComponent(url.hash.slice(1)) : host
    const password = url.username
    if (!password) {
      return null
    }
    const ipFields = assignIpFields(host)
    return {
      label,
      ...ipFields,
      trojanPort: port,
      trojanPassword: decodeURIComponent(password),
    }
  } catch {
    return null
  }
}

const parseVlessUrl = (text: string): ManualNodeInput | null => {
  try {
    const url = new URL(text)
    const host = url.hostname
    const port = toOptionalNumber(url.port || '')
    const uuid = url.username
    if (!host || !port || !uuid) {
      return null
    }
    const label = url.hash ? decodeURIComponent(url.hash.slice(1)) : host
    const publicKey = url.searchParams.get('reality-public-key') || url.searchParams.get('pbk') || undefined
    const shortId = url.searchParams.get('reality-short-id') || url.searchParams.get('sid') || undefined
    const ipFields = assignIpFields(host)
    return {
      label,
      ...ipFields,
      vlessPort: port,
      vlessUUID: decodeURIComponent(uuid),
      vlessPublicKey: publicKey || undefined,
      vlessShortId: shortId || undefined,
    }
  } catch {
    return null
  }
}

const parseHysteriaUrl = (text: string): ManualNodeInput | null => {
  try {
    const url = new URL(text)
    const host = url.hostname
    const port = toOptionalNumber(url.port || '')
    if (!host || !port) {
      return null
    }
    const label = url.hash ? decodeURIComponent(url.hash.slice(1)) : host
    const password = url.username || url.searchParams.get('auth') || url.searchParams.get('password') || ''
    if (!password) {
      return null
    }
    const ipFields = assignIpFields(host)
    return {
      label,
      ...ipFields,
      hysteriaPort: port,
      hysteriaPassword: decodeURIComponent(password),
    }
  } catch {
    return null
  }
}

const parseProtocolUrl = (text: string): ManualNodeInput | null => {
  const lower = text.toLowerCase()
  if (lower.startsWith('ss://')) {
    return parseShadowSocksUrl(text)
  }
  if (lower.startsWith('trojan://')) {
    return parseTrojanUrl(text)
  }
  if (lower.startsWith('vless://')) {
    return parseVlessUrl(text)
  }
  if (lower.startsWith('hysteria2://') || lower.startsWith('hy2://')) {
    return parseHysteriaUrl(text)
  }
  return null
}

const parseProtocolList = (raw: string): ManualNodeInput[] => {
  const matches = raw.match(/((ss|trojan|vless|hysteria2|hy2):\/\/[\S]+)/gi)
  if (!matches) {
    return []
  }
  const inputs: ManualNodeInput[] = []
  for (const entry of matches) {
    const parsed = parseProtocolUrl(entry.trim())
    if (parsed) {
      inputs.push(parsed)
    }
  }
  return inputs
}

const parseImportedNodes = (raw: string): ManualNodeInput[] => {
  try {
    const data = JSON.parse(raw)
    const entries = Array.isArray(data) ? data : [data]
    const inputs: ManualNodeInput[] = []
    for (const item of entries) {
      if (!item || typeof item !== 'object') continue
      const record = item as Record<string, any>
      const label = String(record.label ?? record.name ?? '').trim()
      if (!label) continue
      const ipv4 = typeof record.ipv4 === 'string' ? record.ipv4.trim() : ''
      const ipv6 = typeof record.ipv6 === 'string' ? record.ipv6.trim() : ''
      const input: ManualNodeInput = {
        label,
        ipv4: ipv4 || undefined,
        ipv6: ipv6 || undefined,
        region: typeof record.region === 'string' ? record.region : undefined,
        plan: typeof record.plan === 'string' ? record.plan : undefined,
        ssPort: toOptionalNumber(String(record.ssPort ?? record.port ?? '')) ?? undefined,
        ssPassword: typeof record.ssPassword === 'string' && record.ssPassword.trim()
          ? record.ssPassword.trim()
          : typeof record.password === 'string' && record.password.trim()
            ? record.password.trim()
            : undefined,
        hysteriaPort: toOptionalNumber(String(record.hysteriaPort ?? '')) ?? undefined,
        hysteriaPassword:
          typeof record.hysteriaPassword === 'string' && record.hysteriaPassword.trim()
            ? record.hysteriaPassword.trim()
            : undefined,
        vlessPort: toOptionalNumber(String(record.vlessPort ?? '')) ?? undefined,
        vlessUUID: typeof record.vlessUUID === 'string' && record.vlessUUID.trim() ? record.vlessUUID.trim() : undefined,
        vlessPublicKey:
          typeof record.vlessPublicKey === 'string' && record.vlessPublicKey.trim()
            ? record.vlessPublicKey.trim()
            : undefined,
        vlessShortId:
          typeof record.vlessShortId === 'string' && record.vlessShortId.trim()
            ? record.vlessShortId.trim()
            : undefined,
        trojanPort: toOptionalNumber(String(record.trojanPort ?? '')) ?? undefined,
        trojanPassword:
          typeof record.trojanPassword === 'string' && record.trojanPassword.trim()
            ? record.trojanPassword.trim()
            : undefined,
      }
      inputs.push(input)
    }
    if (inputs.length) {
      return inputs
    }
  } catch {
    // Fallback to protocol parsing
  }
  const protocolInputs = parseProtocolList(raw)
  if (protocolInputs.length) {
    return protocolInputs
  }
  throw new Error('invalid')
}

const handleImportSubmit = async () => {
  const raw = importForm.raw.trim()
  if (!raw) {
    message.error(t('cloud.errors.importEmpty'))
    return false
  }

  let inputs: ManualNodeInput[]
  try {
    inputs = parseImportedNodes(raw)
  } catch {
    message.error(t('cloud.errors.importInvalid'))
    return false
  }

  if (!inputs.length) {
    message.error(t('cloud.errors.importInvalid'))
    return false
  }

  try {
    const { added, skipped } = await cloudStore.addManualNodes(inputs)
    if (!added.length) {
      message.error(t('cloud.errors.importInvalid'))
      return false
    }
    await Promise.all(added.map((node) => cloudStore.applyNodeToProfile(node).catch(() => undefined)))
    if (skipped.length) {
      const detail = skipped.map(formatSkippedImportEntry).join('; ')
      message.warn(t('cloud.manual.importSkippedList', { count: skipped.length, labels: detail }))
    }
    message.success(t('cloud.manual.importSuccess', { count: added.length }))
    return true
  } catch (error) {
    message.error(mapManualError(error))
    return false
  }
}

const openManualNodeModal = () => {
  resetManualForm()
  manualEditingId.value = ''
  modalApi
    .setProps({
      title: t('cloud.manual.addTitle'),
      cancelText: 'common.cancel',
      submitText: 'common.save',
      onOk: handleManualSubmit,
    })
    .setContent(ManualNodeModal, {
      form: manualForm,
      'onUpdate:form': (value: Record<string, any>) => Object.assign(manualForm, value),
    })
    .open()
}

const openImportModal = () => {
  resetImportForm()
  modalApi
    .setProps({
      title: t('cloud.manual.importTitle'),
      cancelText: 'common.cancel',
      submitText: 'common.import',
      onOk: handleImportSubmit,
    })
    .setContent(ImportNodesModal, {
      form: importForm,
      'onUpdate:form': (value: Record<string, any>) => {
        importForm.raw = typeof value?.raw === 'string' ? value.raw : ''
      },
    })
    .open()
}

const openEditManualNode = (record: CloudNode | Record<string, any>) => {
  manualEditingId.value = record.instanceId
  populateManualFormFromNode(record as Record<string, any>)
  modalApi
    .setProps({
      title: t('cloud.manual.editTitle'),
      cancelText: 'common.cancel',
      submitText: 'common.save',
      onOk: handleManualUpdate,
    })
    .setContent(ManualNodeModal, {
      form: manualForm,
      'onUpdate:form': (value: Record<string, any>) => Object.assign(manualForm, value),
    })
    .open()
}

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
  let data = cloudStore.instances.map((node) => ({
    ...node,
    id: node.instanceId,
  }))

  // Apply search filter
  if (searchQuery.value.trim()) {
    const query = searchQuery.value.toLowerCase().trim()
    data = data.filter((node) => {
      return (
        node.label?.toLowerCase().includes(query) ||
        node.ipv4?.toLowerCase().includes(query) ||
        node.ipv6?.toLowerCase().includes(query) ||
        formatNodeRegion(node.region || '').toLowerCase().includes(query) ||
        node.region?.toLowerCase().includes(query)
      )
    })
  }

  // Apply connectivity filter
  if (filterConnectivity.value !== 'all') {
    data = data.filter((node) => node.connectivityStatus === filterConnectivity.value)
  }

  // Apply status filter
  if (filterStatus.value !== 'all') {
    data = data.filter((node) => node.statusText === filterStatus.value)
  }

  // Apply sorting
  if (sortBy.value) {
    data = [...data].sort((a, b) => {
      let aVal: any = a[sortBy.value as keyof typeof a]
      let bVal: any = b[sortBy.value as keyof typeof b]

      // Handle special cases
      if (sortBy.value === 'createdAt') {
        aVal = new Date(aVal || 0).getTime()
        bVal = new Date(bVal || 0).getTime()
      }

      // Handle undefined/null
      if (aVal == null) return 1
      if (bVal == null) return -1

      // Compare
      if (aVal < bVal) return sortOrder.value === 'asc' ? -1 : 1
      if (aVal > bVal) return sortOrder.value === 'asc' ? 1 : -1
      return 0
    })
  }

  return data
})

const lastInstancesUpdateRelative = computed(() => {
  if (!cloudStore.instancesUpdatedAt) {
    return ''
  }
  return formatRelativeTime(cloudStore.instancesUpdatedAt)
})

const lastInstancesUpdateExact = computed(() => {
  if (!cloudStore.instancesUpdatedAt) {
    return ''
  }
  return formatDate(cloudStore.instancesUpdatedAt, 'YYYY-MM-DD HH:mm:ss')
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
  { title: 'selection', key: 'selection', width: '40px' },
  { title: 'cloud.table.label', key: 'label', width: '11%' },
  { title: 'cloud.table.region', key: 'region', width: '9%' },
  { title: 'cloud.table.plan', key: 'plan', width: '11%' },
  { title: 'cloud.table.ipAddresses', key: 'ipAddresses', width: '12%' },
  { title: 'cloud.table.protocols', key: 'protocols', width: '17%' },
  { title: 'cloud.table.status', key: 'status', width: '13%' },
  { title: 'cloud.table.connectivity', key: 'connectivity', width: '8%' },
  { title: 'cloud.table.createdAt', key: 'createdAt', width: '8%' },
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

// Latency testing functions
const testLatencySilently = async () => {
  if (!hasApiKey.value || cloudStore.regions.length === 0 || testingLatency.value) {
    return
  }

  // Use cached results if available and valid (24-hour TTL)
  if (cloudStore.isLatencyCacheValid() && latencyResults.value.length > 0) {
    console.log('[CloudView] Using cached latency results')
    return
  }

  console.log('[CloudView] Auto-testing region latency...')
  testingLatency.value = true

  try {
    const result = await TestAllCloudRegions()

    if (!result.flag) {
      console.warn('[CloudView] Latency test failed:', result.data)
      return
    }

    const results: RegionLatency[] = JSON.parse(result.data)
    latencyResults.value = results

    // Update cache
    cloudStore.latencyTestResults = {}
    results.forEach((r) => {
      if (r.status === 'ok') {
        cloudStore.latencyTestResults[r.code] = r.latency
      }
    })
    cloudStore.latencyUpdatedAt = Date.now()

    console.log('[CloudView] Latency test completed and cached, results:', results.length)

    // Auto-select the fastest region if no region is selected
    if (!form.region) {
      const fastest = results.find((r) => r.status === 'ok')
      if (fastest) {
        form.region = fastest.code
        console.log('[CloudView] Auto-selected fastest region:', fastest.name, fastest.latency + 'ms')
      }
    }
  } catch (error) {
    console.error('[CloudView] Latency test error:', error)
  } finally {
    testingLatency.value = false
  }
}

const handleTestLatency = async () => {
  console.log('[CloudView] Manual latency test triggered - forcing refresh')

  if (!hasApiKey.value) {
    message.warn(t('cloud.latency.noApiKey'))
    return
  }

  testingLatency.value = true
  latencyResults.value = []

  try {
    const result = await TestAllCloudRegions()

    if (!result.flag) {
      throw new Error(result.data)
    }

    const results: RegionLatency[] = JSON.parse(result.data)
    latencyResults.value = results
    showLatencyResults.value = true

    // Update cache with fresh results
    cloudStore.latencyTestResults = {}
    results.forEach((r) => {
      if (r.status === 'ok') {
        cloudStore.latencyTestResults[r.code] = r.latency
      }
    })
    cloudStore.latencyUpdatedAt = Date.now()
    console.log('[CloudView] Latency cache updated with manual test results')

    // Auto-select the fastest region
    const fastest = results.find((r) => r.status === 'ok')
    if (fastest) {
      form.region = fastest.code
      message.success(
        t('cloud.latency.testComplete', {
          region: fastest.name,
          latency: fastest.latency.toFixed(1),
        })
      )
    } else {
      message.warn(t('cloud.latency.noAvailableRegion'))
    }
  } catch (error) {
    logError('TestLatency', error)
    message.error(t('cloud.latency.testFailed'))
  } finally {
    testingLatency.value = false
  }
}

watch(
  () => [cloudStore.regions.length, cloudStore.plans.length, cloudStore.config.defaultPlan, cloudStore.config.defaultRegion],
  applyDefaults,
)

// Auto-test latency when regions are loaded and API key is available
watch(
  () => [cloudStore.regions.length, hasApiKey.value] as const,
  ([regionsCount, hasKey]) => {
    if (regionsCount > 0 && hasKey && latencyResults.value.length === 0) {
      // Delay a bit to ensure the UI is ready
      setTimeout(() => {
        testLatencySilently()
      }, 500)
    }
  },
  { immediate: true }
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
  { flush: 'post' }, // Defer execution until after DOM updates for better performance
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
  // 清理本组件的定时器
  if (refreshIntervalId.value !== null) {
    clearInterval(refreshIntervalId.value)
    refreshIntervalId.value = null
  }

  // 清理cloudStore中的所有定时器，防止内存泄漏
  cloudStore.clearAllTimers()
})

onMounted(async () => {
  try {
    // Load available providers and get current provider
    await Promise.allSettled([cloudStore.loadProviders(), cloudStore.getCurrentProvider()])

    await cloudStore.loadManualNodes()

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

const handleBackupConfig = async () => {
  try {
    const backupData = {
      cloudConfig: cloudStore.config,
    }
    const backupString = await createBackup(backupData)
    downloadBackup(backupString)
    message.success(t('cloud.backup.exported'))
  } catch (error) {
    message.error(t('cloud.backup.exportFailed'))
    handleError(error)
  }
}

const handleRestoreConfig = async () => {
  try {
    // Create file input
    const input = document.createElement('input')
    input.type = 'file'
    input.accept = '.json'
    input.onchange = async (e) => {
      const file = (e.target as HTMLInputElement).files?.[0]
      if (!file) return

      const reader = new FileReader()
      reader.onload = async (event) => {
        try {
          const backupString = event.target?.result as string
          const backup = parseBackup(backupString)

          // Restore cloud config
          if (backup.cloudConfig) {
            cloudStore.config = backup.cloudConfig
            await cloudStore.saveConfig()
          }

          message.success(t('cloud.backup.imported'))

          // Refresh data after restore
          await fetchMeta()
        } catch (error) {
          message.error(t('cloud.backup.importFailed'))
          handleError(error)
        }
      }
      reader.readAsText(file)
    }
    input.click()
  } catch (error) {
    message.error(t('cloud.backup.importFailed'))
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

const handleTestAllConnectivity = async () => {
  try {
    await cloudStore.testAllNodesConnectivity()
    message.success(t('cloud.connectivity.testAll') + ' completed')
  } catch (error) {
    handleError(error)
  }
}

const handleShowRecommendations = () => {
  const allNodes = cloudStore.instances

  if (allNodes.length === 0) {
    message.info(t('cloud.recommendations.noNodes'))
    return
  }

  // Build latency map from cached results
  const latencyMap = new Map<string, number>()
  if (latencyResults.value.length > 0) {
    latencyResults.value.forEach(r => {
      if (r.status === 'ok') {
        latencyMap.set(r.code, r.latency)
      }
    })
  }

  // Get top 5 recommended nodes
  const recommendations = getRecommendedNodes(allNodes, {
    preferLowLatency: true,
    preferLowRisk: true,
    preferReachable: true,
    preferRecent: false,
  }, latencyMap)

  // Build recommendation message
  const topNodes = recommendations.slice(0, 5)
  if (topNodes.length === 0) {
    message.info(t('cloud.recommendations.noneAvailable'))
    return
  }

  const recommendationText = topNodes.map((result, index) => {
    const { node, score, reasons } = result
    const ipv4 = node.ipv4 || 'N/A'
    const region = node.region ? formatNodeRegion(node.region) : 'N/A'
    return `${index + 1}. ${node.label} (${region})\n   Score: ${score}/100\n   IP: ${ipv4}\n   ${reasons.join(', ')}`
  }).join('\n\n')

  // Show recommendations using console log since there's no modal API
  // User can see detailed recommendations in browser console
  console.log('=== Recommended Nodes ===\n' + recommendationText)
  message.success(t('cloud.recommendations.title') + ': Check console for details')
}

// Batch operations
const toggleNodeSelection = (nodeId: string) => {
  if (selectedNodeIds.value.has(nodeId)) {
    selectedNodeIds.value.delete(nodeId)
  } else {
    selectedNodeIds.value.add(nodeId)
  }
  // Trigger reactivity
  selectedNodeIds.value = new Set(selectedNodeIds.value)
}

const toggleSelectAll = () => {
  if (selectedNodeIds.value.size === tableData.value.length) {
    selectedNodeIds.value.clear()
  } else {
    tableData.value.forEach(node => selectedNodeIds.value.add(node.instanceId))
  }
  // Trigger reactivity
  selectedNodeIds.value = new Set(selectedNodeIds.value)
}

const clearSelection = () => {
  selectedNodeIds.value.clear()
  selectedNodeIds.value = new Set(selectedNodeIds.value)
}

const handleBatchTestConnectivity = async () => {
  if (selectedNodeIds.value.size === 0) {
    message.info(t('cloud.batch.noSelection'))
    return
  }

  batchOperating.value = true
  try {
    const promises = Array.from(selectedNodeIds.value).map(id =>
      cloudStore.testNodeConnectivity(id)
    )
    await Promise.all(promises)
    message.success(t('cloud.batch.testComplete', { count: selectedNodeIds.value.size }))
  } catch (error) {
    handleError(error)
  } finally {
    batchOperating.value = false
  }
}

const handleBatchRotateIP = async () => {
  if (selectedNodeIds.value.size === 0) {
    message.info(t('cloud.batch.noSelection'))
    return
  }

  const confirmed = await confirm(
    t('cloud.batch.rotateIP'),
    t('cloud.batch.rotateConfirm', { count: selectedNodeIds.value.size })
  )
  if (!confirmed) return

  batchOperating.value = true
  let successCount = 0
  let failCount = 0

  try {
    for (const nodeId of selectedNodeIds.value) {
      try {
        await cloudStore.rotateIP(nodeId)
        successCount++
      } catch (error) {
        failCount++
        logError(`[CloudView] Failed to rotate IP for ${nodeId}:`, error)
      }
    }

    if (successCount > 0) {
      message.success(t('cloud.batch.rotateComplete', { success: successCount, fail: failCount }))
    } else {
      message.error(t('cloud.batch.allFailed'))
    }

    clearSelection()
    await cloudStore.refreshInstances(true)
  } catch (error) {
    handleError(error)
  } finally {
    batchOperating.value = false
  }
}

const handleBatchDestroy = async () => {
  if (selectedNodeIds.value.size === 0) {
    message.info(t('cloud.batch.noSelection'))
    return
  }

  const confirmed = await confirm(
    t('cloud.batch.destroy'),
    t('cloud.batch.destroyConfirm', { count: selectedNodeIds.value.size })
  )
  if (!confirmed) return

  batchOperating.value = true
  let successCount = 0
  let failCount = 0

  try {
    for (const nodeId of selectedNodeIds.value) {
      try {
        await cloudStore.destroyInstance(nodeId)
        successCount++
      } catch (error) {
        failCount++
        logError(`[CloudView] Failed to destroy ${nodeId}:`, error)
      }
    }

    if (successCount > 0) {
      message.success(t('cloud.batch.destroyComplete', { success: successCount, fail: failCount }))
    } else {
      message.error(t('cloud.batch.allFailed'))
    }

    clearSelection()
    await cloudStore.refreshInstances(true)
  } catch (error) {
    handleError(error)
  } finally {
    batchOperating.value = false
  }
}

// Search and filter handlers
const handleSort = (column: string) => {
  if (sortBy.value === column) {
    // Toggle sort order
    sortOrder.value = sortOrder.value === 'asc' ? 'desc' : 'asc'
  } else {
    // New column, default to ascending
    sortBy.value = column
    sortOrder.value = 'asc'
  }
}

const clearFilters = () => {
  searchQuery.value = ''
  filterConnectivity.value = 'all'
  filterStatus.value = 'all'
  sortBy.value = ''
  sortOrder.value = 'asc'
}

const hasActiveFilters = computed(() => {
  return (
    searchQuery.value.trim() !== '' ||
    filterConnectivity.value !== 'all' ||
    filterStatus.value !== 'all'
  )
})

// Visualization handlers
const handleViewCharts = (node: ManagedCloudNode) => {
  viewingChartNode.value = node
  showChartsModal.value = true
}

const closeChartsModal = () => {
  showChartsModal.value = false
  viewingChartNode.value = null
}

const connectivityChartData = computed<ConnectivityDataPoint[]>(() => {
  if (!viewingChartNode.value) return []
  // Generate mock data based on current connectivity status
  // In production, this would come from backend tracking
  return generateMockConnectivityHistory(
    viewingChartNode.value.connectivityStatus || 'unknown',
    24 // 24 hours
  )
})

const latencyChartData = computed<LatencyDataPoint[]>(() => {
  if (!viewingChartNode.value) return []
  // Generate mock latency data
  // In production, this would come from backend tracking
  const data: LatencyDataPoint[] = []
  const now = Date.now()
  const interval = (24 * 60 * 60 * 1000) / 48 // 48 data points over 24 hours

  // Use a default latency as base (no latency tracking in current data model)
  // In production, this would come from backend latency tracking
  const baseLatency = 100

  for (let i = 0; i < 48; i++) {
    const variance = (Math.random() - 0.5) * 40 // +/- 20ms variance
    data.push({
      timestamp: now - (48 - i) * interval,
      latency: Math.max(0, baseLatency + variance),
    })
  }

  return data
})

const handleDeploy = async () => {
  if (disableDeploy.value) {
    message.error(t('cloud.errors.formIncomplete'))
    return
  }
  try {
    message.info(t('cloud.create.deployingHint'))
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
    await cloudStore.refreshInstances(true)
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

const rotatingNodeId = ref('')

const handleRotateIP = async (record: CloudNode | Record<string, any>) => {
  const node = record as CloudNode

  // Check if it's a manual node
  if (isManualNode(node)) {
    message.error(t('cloud.nodes.rotateIPBlocked'))
    return
  }

  try {
    await confirm('common.warning', t('cloud.nodes.rotateIPConfirm'))
  } catch {
    return
  }

  rotatingNodeId.value = node.instanceId
  try {
    const newNode = await cloudStore.rotateIP(node.instanceId)
    message.success(t('cloud.nodes.rotateIPSuccess'))
    logInfo('[CloudView] IP rotated successfully. New node:', newNode.instanceId)
  } catch (error) {
    handleError(error)
  } finally {
    rotatingNodeId.value = ''
  }
}

const handleDestroy = async (record: CloudNode | Record<string, any>) => {
  const node = record as CloudNode
  try {
    const messageText = isManualNode(node)
      ? t('cloud.manual.confirmRemove', { label: node.label })
      : t('cloud.confirmDestroy', { label: node.label })
    await confirm('common.warning', messageText)
  } catch {
    return
  }
  try {
    await cloudStore.destroyInstance(node.instanceId)
    message.success('common.success')
  } catch (error) {
    handleError(error)
  }
}

// Quick operations for context menu
const handleCopyNodeConfig = async (node: ManagedCloudNode) => {
  try {
    // Build configuration text with all node details
    const ipv4 = node.ipv4 || 'N/A'
    const ipv6 = node.ipv6 || 'N/A'
    const protocols = []

    if (node.ssPort && node.ssPassword) {
      protocols.push(`Shadowsocks: ${ipv4}:${node.ssPort} (${node.ssPassword})`)
    }
    if (node.hysteriaPort && node.hysteriaPassword) {
      protocols.push(`Hysteria2: ${ipv4}:${node.hysteriaPort} (${node.hysteriaPassword})`)
    }
    if (node.vlessPort && node.vlessUUID) {
      protocols.push(`VLESS: ${ipv4}:${node.vlessPort} (UUID: ${node.vlessUUID})`)
    }
    if (node.trojanPort && node.trojanPassword) {
      protocols.push(`Trojan: ${ipv4}:${node.trojanPort} (${node.trojanPassword})`)
    }

    const configText = `
Node: ${node.label}
Region: ${node.region ? formatNodeRegion(node.region) : 'N/A'}
IPv4: ${ipv4}
IPv6: ${ipv6}

Protocols:
${protocols.join('\n')}
`.trim()

    await ClipboardSetText(configText)
    message.success(t('cloud.quickActions.configCopied'))
  } catch (error) {
    logError('CopyNodeConfig', error)
    message.error(t('cloud.quickActions.copyFailed'))
  }
}

const handleQuickTestConnectivity = async (node: ManagedCloudNode) => {
  try {
    message.info(t('cloud.quickActions.testingConnectivity'))
    await cloudStore.testNodeConnectivity(node.instanceId)
    const status = node.connectivityStatus || 'unknown'
    const statusText = getConnectivityLabel(status)
    message.success(t('cloud.quickActions.testComplete', { status: statusText }))
  } catch (error) {
    logError('QuickTestConnectivity', error)
    message.error(t('cloud.quickActions.testFailed'))
  }
}

// Context menu for table rows
const tableContextMenu = computed(() => [
  {
    label: t('cloud.quickActions.useNode'),
    handler: (record: ManagedCloudNode) => handleUseNode(record),
  },
  {
    label: t('cloud.quickActions.copyConfig'),
    handler: (record: ManagedCloudNode) => handleCopyNodeConfig(record),
  },
  {
    label: t('cloud.quickActions.testConnectivity'),
    handler: (record: ManagedCloudNode) => handleQuickTestConnectivity(record),
  },
  {
    label: t('cloud.quickActions.rotateIP'),
    handler: (record: ManagedCloudNode) => handleRotateIP(record),
    hidden: (record: ManagedCloudNode) => isManualNode(record) || record.connectivityStatus !== 'blocked',
  },
  {
    label: t('cloud.quickActions.destroy'),
    handler: (record: ManagedCloudNode) => handleDestroy(record),
  },
])

// Keyboard shortcuts, health checks, and offline mode
onMounted(() => {
  // Initialize offline mode detection
  const cleanupOfflineMode = initOfflineMode()

  const handleKeyDown = (e: KeyboardEvent) => {
    // ? - Show keyboard shortcuts help
    if (e.key === '?' && !e.ctrlKey && !e.metaKey && !e.altKey) {
      e.preventDefault()
      showKeyboardHelp.value = true
      return
    }

    // Escape - Close help modal
    if (e.key === 'Escape' && showKeyboardHelp.value) {
      e.preventDefault()
      showKeyboardHelp.value = false
      return
    }

    // Ctrl+T or Cmd+T - Test all nodes connectivity
    if ((e.ctrlKey || e.metaKey) && e.key === 't') {
      e.preventDefault()
      if (cloudStore.instances.length > 0) {
        cloudStore.testAllNodesConnectivity()
        message.info(t('cloud.quickActions.testingAll'))
      }
    }

    // Ctrl+R or Cmd+R - Refresh instances
    if ((e.ctrlKey || e.metaKey) && e.key === 'r') {
      e.preventDefault()
      cloudStore.refreshInstances(false, true) // Force refresh
      message.info(t('cloud.quickActions.refreshing'))
    }

    // Ctrl+F or Cmd+F - Focus search box
    if ((e.ctrlKey || e.metaKey) && e.key === 'f') {
      e.preventDefault()
      const searchInput = document.querySelector('input[placeholder*="Search"]') as HTMLInputElement
      if (searchInput) {
        searchInput.focus()
      }
    }
  }

  window.addEventListener('keydown', handleKeyDown)

  // Schedule periodic health checks (every 5 minutes)
  const performHealthCheck = () => {
    const allNodes = cloudStore.instances
    if (allNodes.length === 0) return

    const healthResults = checkAllNodesHealth(allNodes)
    const summary = getHealthSummary(healthResults)

    logInfo(`[CloudView] Health check: ${summary.healthy}/${summary.total} healthy nodes (avg score: ${summary.avgScore})`)

    // Warn if there are critical issues
    if (summary.criticalIssues > 0) {
      logInfo(`[CloudView] Warning: ${summary.criticalIssues} nodes have critical health issues`)
    }
  }

  const stopHealthChecks = scheduleHealthChecks(performHealthCheck, 5 * 60 * 1000)

  onUnmounted(() => {
    window.removeEventListener('keydown', handleKeyDown)
    stopHealthChecks()
    cleanupOfflineMode()
  })
})
</script>

<template>
  <div class="cloud-view grid gap-16">
    <Card>
      <template #title>
        <div class="flex items-center gap-8">
          <span>{{ t('cloud.credentials.title') }}</span>
          <span v-if="!isOnline" class="text-12 px-8 py-2 rounded bg-yellow-500/20 text-yellow-600">
            {{ t('cloud.offline.indicator') }}
          </span>
        </div>
      </template>
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
          <Button
            @click="handleBackupConfig"
            type="link"
            :disabled="!hasApiKey"
          >
            {{ t('cloud.backup.export') }}
          </Button>
          <Button
            @click="handleRestoreConfig"
            type="link"
          >
            {{ t('cloud.backup.import') }}
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
            @click="handleTestLatency"
            type="normal"
            :loading="testingLatency"
            :disabled="!hasApiKey || testingLatency"
          >
            {{ testingLatency ? t('cloud.latency.testing') : t('cloud.latency.test') }}
          </Button>
          <Button
            @click="handleRefreshInstances"
            type="link"
            :loading="cloudStore.loadingInstances"
            :disabled="!hasApiKey"
          >
            {{ t('cloud.create.refresh') }}
          </Button>
          <Button
            @click="handleTestAllConnectivity"
            type="link"
            :disabled="!hasApiKey || tableData.length === 0"
          >
            {{ t('cloud.connectivity.testAll') }}
          </Button>
          <Button
            @click="handleShowRecommendations"
            type="link"
            :disabled="tableData.length === 0"
          >
            {{ t('cloud.recommendations.showButton') }}
          </Button>
          <Button @click="openManualNodeModal" type="normal">
            {{ t('cloud.manual.add') }}
          </Button>
          <Button @click="openImportModal" type="normal">
            {{ t('cloud.manual.import') }}
          </Button>
        </div>
        <div v-if="cloudStore.creatingInstance" class="text-12 text-tertiary">
          {{ t('cloud.create.deployingProgress') }}
        </div>
      </div>
    </Card>

    <Card :title="t('cloud.nodes.title')">
      <div class="flex flex-col gap-12 py-8">
        <div
          v-if="cloudStore.loadingInstances || lastInstancesUpdateRelative"
          class="flex flex-wrap items-center justify-between gap-6 text-12 text-secondary"
        >
          <div class="flex flex-wrap items-center gap-4">
            <span v-if="cloudStore.loadingInstances">{{ t('cloud.nodes.loading') }}</span>
            <span v-if="cloudStore.loadingInstances" class="text-tertiary">
              {{ t('cloud.nodes.loadingHint') }}
            </span>
          </div>
          <div
            v-if="lastInstancesUpdateRelative"
            class="flex items-center gap-2 text-tertiary"
            :title="lastInstancesUpdateExact || ''"
          >
            {{ t('cloud.nodes.lastSynced', { time: lastInstancesUpdateRelative }) }}
          </div>
        </div>

        <div v-if="!tableData.length">
          <div v-if="cloudStore.loadingInstances" class="py-32 text-center text-14">
            <div>{{ t('cloud.nodes.loading') }}</div>
            <div class="mt-6 text-12 text-tertiary">
              {{ t('cloud.nodes.loadingHint') }}
            </div>
          </div>
          <div v-else class="py-32">
            <Empty>
              <template #description>{{ t('cloud.nodes.empty') }}</template>
            </Empty>
          </div>
        </div>

        <!-- Search and Filter Controls -->
        <div v-if="tableData.length || hasActiveFilters" class="flex flex-wrap items-center gap-8">
          <!-- Search Box -->
          <div class="flex-1 min-w-200">
            <Input
              v-model="searchQuery"
              :placeholder="t('cloud.search.placeholder')"
              size="small"
              clearable
            />
          </div>

          <!-- Connectivity Filter -->
          <Select
            v-model="filterConnectivity"
            :options="[
              { label: t('cloud.filter.allConnectivity'), value: 'all' },
              { label: t('cloud.connectivity.reachable'), value: 'reachable' },
              { label: t('cloud.connectivity.icmp_blocked'), value: 'icmp_blocked' },
              { label: t('cloud.connectivity.blocked'), value: 'blocked' },
              { label: t('cloud.connectivity.testing'), value: 'testing' },
              { label: t('cloud.connectivity.unknown'), value: 'unknown' },
            ]"
            :placeholder="t('cloud.filter.connectivity')"
            size="small"
            class="min-w-120"
          />

          <!-- Status Filter -->
          <Select
            v-model="filterStatus"
            :options="[
              { label: t('cloud.filter.allStatus'), value: 'all' },
              { label: t('cloud.status.unknown'), value: 'unknown' },
              { label: t('cloud.status.pending'), value: 'pending' },
              { label: t('cloud.status.applying'), value: 'applying' },
              { label: t('cloud.status.connected'), value: 'connected' },
              { label: t('cloud.status.error'), value: 'error' },
            ]"
            :placeholder="t('cloud.filter.status')"
            size="small"
            class="min-w-120"
          />

          <!-- Sort By -->
          <Select
            v-model="sortBy"
            :options="[
              { label: t('cloud.sort.default'), value: '' },
              { label: t('cloud.table.label'), value: 'label' },
              { label: t('cloud.table.region'), value: 'region' },
              { label: t('cloud.table.status'), value: 'status' },
              { label: t('cloud.table.createdAt'), value: 'createdAt' },
            ]"
            :placeholder="t('cloud.sort.sortBy')"
            size="small"
            class="min-w-140"
          />

          <!-- Sort Order Toggle -->
          <Button
            v-if="sortBy"
            @click="sortOrder = sortOrder === 'asc' ? 'desc' : 'asc'"
            type="text"
            size="small"
            :title="sortOrder === 'asc' ? t('cloud.sort.ascending') : t('cloud.sort.descending')"
          >
            {{ sortOrder === 'asc' ? '↑' : '↓' }}
          </Button>

          <!-- Clear Filters Button -->
          <Button
            v-if="hasActiveFilters || sortBy"
            @click="clearFilters"
            type="text"
            size="small"
          >
            {{ t('cloud.filter.clear') }}
          </Button>

          <!-- Result Count -->
          <span v-if="hasActiveFilters" class="text-12 text-secondary">
            {{ t('cloud.search.results', { count: tableData.length }) }}
          </span>
        </div>

        <!-- Batch operations toolbar -->
        <div v-if="selectedNodeIds.size > 0" class="flex flex-wrap items-center gap-8 p-12 bg-primary/5 rounded">
          <span class="text-14 font-medium">{{ t('cloud.batch.selected', { count: selectedNodeIds.size }) }}</span>
          <Button
            @click="handleBatchTestConnectivity"
            type="normal"
            size="small"
            :loading="batchOperating"
          >
            {{ t('cloud.batch.testConnectivity') }}
          </Button>
          <Button
            @click="handleBatchRotateIP"
            type="normal"
            size="small"
            :loading="batchOperating"
          >
            {{ t('cloud.batch.rotateIP') }}
          </Button>
          <Button
            @click="handleBatchDestroy"
            type="normal"
            size="small"
            :loading="batchOperating"
          >
            {{ t('cloud.batch.destroy') }}
          </Button>
          <Button
            @click="clearSelection"
            type="link"
            size="small"
          >
            {{ t('common.cancel') }}
          </Button>
        </div>

        <div v-else class="py-8">
          <Table :columns="columns" :data-source="tableData" :menu="tableContextMenu" @row-click="(record: any) => toggleNodeSelection(record.instanceId)">
            <template #selection="{ record }">
              <div class="flex items-center justify-center" @click.stop>
                <input
                  type="checkbox"
                  :checked="selectedNodeIds.has(record.instanceId)"
                  @change="toggleNodeSelection(record.instanceId)"
                  class="cursor-pointer w-16 h-16"
                />
              </div>
            </template>
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
                <Tag v-if="isManualNode(record)" color="cyan" size="small">
                  {{ t('cloud.manual.badge') }}
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
            <template #connectivity="{ record }">
              <div class="flex flex-col gap-2">
                <Tag
                  v-if="record.connectivityStatus"
                  :color="getConnectivityColor(record.connectivityStatus)"
                  size="small"
                >
                  {{ getConnectivityLabel(record.connectivityStatus) }}
                </Tag>
                <span v-else class="text-secondary">-</span>
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
              <Button
                v-if="isManualNode(record)"
                @click="openEditManualNode(record)"
                type="text"
                size="small"
              >
                {{ t('cloud.manual.edit') }}
              </Button>
              <Button @click="copyNodeConfig(record)" type="text" size="small" v-tips="'cloud.nodes.copyLink'">📋</Button>
              <Button @click="handleViewCharts(record as ManagedCloudNode)" type="text" size="small" v-tips="'cloud.charts.view'">📊</Button>
              <Button
                v-if="!isManualNode(record) && record.connectivityStatus === 'blocked'"
                @click="handleRotateIP(record)"
                type="text"
                size="small"
                :loading="rotatingNodeId === record.instanceId"
              >
                {{ rotatingNodeId === record.instanceId ? t('cloud.nodes.rotatingIP') : t('cloud.nodes.rotateIP') }}
              </Button>
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
      </div>
    </Card>
  </div>

  <Modal />

  <!-- Charts Modal -->
  <Modal v-if="showChartsModal" @close="closeChartsModal">
    <template #title>
      {{ t('cloud.charts.title', { label: viewingChartNode?.label || '' }) }}
    </template>
    <div v-if="viewingChartNode" class="charts-modal-content">
      <div class="chart-section">
        <ConnectivityChart
          :title="t('cloud.charts.connectivity')"
          :data="connectivityChartData"
          :width="600"
          :height="80"
        />
      </div>
      <div class="chart-section">
        <LatencyChart
          :title="t('cloud.charts.latency')"
          :data="latencyChartData"
          :width="600"
          :height="120"
        />
      </div>
      <div class="chart-note">
        <span>{{ t('cloud.charts.note') }}</span>
      </div>
    </div>
  </Modal>

  <!-- Keyboard Shortcuts Help Modal -->
  <Modal v-if="showKeyboardHelp" @close="showKeyboardHelp = false">
    <template #title>
      {{ t('cloud.shortcuts.title') }}
    </template>
    <div class="shortcuts-help">
      <div class="shortcuts-section">
        <h3 class="shortcuts-section-title">{{ t('cloud.shortcuts.general') }}</h3>
        <div class="shortcut-item">
          <kbd>?</kbd>
          <span>{{ t('cloud.shortcuts.showHelp') }}</span>
        </div>
        <div class="shortcut-item">
          <kbd>Esc</kbd>
          <span>{{ t('cloud.shortcuts.closeModal') }}</span>
        </div>
      </div>

      <div class="shortcuts-section">
        <h3 class="shortcuts-section-title">{{ t('cloud.shortcuts.navigation') }}</h3>
        <div class="shortcut-item">
          <kbd>Ctrl</kbd> + <kbd>F</kbd>
          <span>{{ t('cloud.shortcuts.focusSearch') }}</span>
        </div>
        <div class="shortcut-item">
          <kbd>Ctrl</kbd> + <kbd>R</kbd>
          <span>{{ t('cloud.shortcuts.refresh') }}</span>
        </div>
      </div>

      <div class="shortcuts-section">
        <h3 class="shortcuts-section-title">{{ t('cloud.shortcuts.actions') }}</h3>
        <div class="shortcut-item">
          <kbd>Ctrl</kbd> + <kbd>T</kbd>
          <span>{{ t('cloud.shortcuts.testAll') }}</span>
        </div>
      </div>

      <div class="shortcuts-note">
        {{ t('cloud.shortcuts.note') }}
      </div>
    </div>
  </Modal>
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

/* Charts Modal */
.charts-modal-content {
  display: flex;
  flex-direction: column;
  gap: 16px;
  padding: 16px 0;
}

.chart-section {
  border: 1px solid var(--divider-color);
  border-radius: 4px;
  overflow: hidden;
}

.chart-note {
  font-size: 12px;
  color: var(--text-secondary-color);
  font-style: italic;
  text-align: center;
  padding: 8px;
  background: #fafafa;
  border-radius: 4px;
}

/* Keyboard Shortcuts Help */
.shortcuts-help {
  display: flex;
  flex-direction: column;
  gap: 24px;
  padding: 16px 0;
}

.shortcuts-section {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.shortcuts-section-title {
  font-size: 14px;
  font-weight: 600;
  color: var(--text-primary-color);
  margin: 0 0 8px 0;
  padding-bottom: 8px;
  border-bottom: 1px solid var(--divider-color);
}

.shortcut-item {
  display: flex;
  align-items: center;
  gap: 16px;
  font-size: 13px;
}

.shortcut-item kbd {
  display: inline-block;
  padding: 4px 8px;
  font-family: monospace;
  font-size: 12px;
  font-weight: 600;
  color: #333;
  background: #f5f5f5;
  border: 1px solid #ccc;
  border-radius: 4px;
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.1);
  min-width: 32px;
  text-align: center;
}

.shortcut-item span {
  flex: 1;
  color: var(--text-secondary-color);
}

.shortcuts-note {
  font-size: 12px;
  color: var(--text-tertiary-color);
  font-style: italic;
  text-align: center;
  padding: 12px;
  background: #fafafa;
  border-radius: 4px;
  margin-top: 8px;
}
</style>
