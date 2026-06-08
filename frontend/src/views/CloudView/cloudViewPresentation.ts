import type { ManagedCloudNode } from '@/stores/cloud'
import type { CloudPlan, CloudProvider, CloudRegion, RegionLatency } from '@/types/cloud'

type TranslateFn = (key: string, params?: Record<string, unknown>) => string

export type RiskLevel = 'low' | 'medium' | 'high' | 'critical'
export type StatusKey = 'unknown' | 'pending' | 'applying' | 'connected' | 'error'
export type TagColor = 'cyan' | 'green' | 'red' | 'default' | 'primary'
export type RegionOption = {
  label: string
  value: string
  latency: number
  status: string
  riskLevel: RiskLevel
}

type TableSortOrder = 'asc' | 'desc'
type TableDataOptions = {
  searchQuery: string
  filterConnectivity: string
  filterStatus: string
  sortBy: string
  sortOrder: TableSortOrder
  formatNodeRegion: (regionId: string) => string
}

const reachabilityRiskRating: Record<string, RiskLevel> = {
  sgp: 'low',
  nrt: 'low',
  icn: 'low',
  hkg: 'medium',
  tpe: 'low',
  bom: 'low',
  syd: 'low',
  lax: 'medium',
  sjc: 'medium',
  sea: 'medium',
  ams: 'medium',
  fra: 'medium',
  lhr: 'medium',
  ewr: 'high',
  ord: 'high',
  dfw: 'high',
  mia: 'high',
  atl: 'high',
  yto: 'high',
  cdg: 'high',
  default: 'medium',
}

const statusColors: Record<StatusKey, TagColor> = {
  unknown: 'default',
  pending: 'green',
  applying: 'cyan',
  connected: 'primary',
  error: 'red',
}

const connectivityColors: Record<string, TagColor> = {
  reachable: 'green',
  icmp_blocked: 'cyan',
  blocked: 'red',
  testing: 'default',
  unknown: 'default',
}

export const getRiskLevel = (regionId: string): RiskLevel => {
  return reachabilityRiskRating[regionId] || reachabilityRiskRating.default
}

export const getRiskIcon = (risk: RiskLevel): string => {
  const iconMap: Record<RiskLevel, string> = {
    low: '🟢',
    medium: '🟡',
    high: '🟠',
    critical: '🔴',
  }
  return iconMap[risk]
}

export const formatRegion = (
  region: CloudRegion,
  provider: CloudProvider,
  translate: TranslateFn,
): string => {
  if (provider === 'digitalocean') {
    return region.city
  }

  const cityKey = `cloud.regions.${region.city}`
  const countryKey = `cloud.regions.${region.country}`
  const city = translate(cityKey) !== cityKey ? translate(cityKey) : region.city
  const country = translate(countryKey) !== countryKey ? translate(countryKey) : region.country
  return `${city}, ${country}`
}

export const buildRegionOptions = (
  regions: CloudRegion[],
  latencyResults: RegionLatency[],
  provider: CloudProvider,
  translate: TranslateFn,
): RegionOption[] => {
  const latencyMap = new Map<string, RegionLatency>()
  latencyResults.forEach((result) => {
    latencyMap.set(result.code, result)
  })

  const regionsWithInfo = regions.map((region) => {
    const latency = latencyMap.get(region.id)
    const riskLevel = getRiskLevel(region.id)
    const riskIcon = getRiskIcon(riskLevel)
    const regionLabel = formatRegion(region, provider, translate)

    let label = `${riskIcon} ${regionLabel}`
    if (latency) {
      label = latency.status === 'ok'
        ? `${riskIcon} ${regionLabel} · ${latency.latency.toFixed(0)}ms`
        : `${riskIcon} ${regionLabel} · ${translate('cloud.latency.timeout')}`
    }

    return {
      label,
      value: region.id,
      latency: latency?.latency || 9999,
      status: latency?.status || 'unknown',
      riskLevel,
    }
  })

  const riskOrder: Record<RiskLevel, number> = { low: 0, medium: 1, high: 2, critical: 3 }
  return regionsWithInfo.sort((a, b) => {
    const riskDiff = riskOrder[a.riskLevel] - riskOrder[b.riskLevel]
    if (riskDiff !== 0) return riskDiff
    if (a.status === 'timeout' && b.status !== 'timeout') return 1
    if (a.status !== 'timeout' && b.status === 'timeout') return -1
    return a.latency - b.latency
  })
}

export const getStatusLabel = (status: string | undefined, translate: TranslateFn): string => {
  const key = (status || 'unknown') as StatusKey
  return translate(`cloud.status.${key}`)
}

export const getStatusColor = (status?: string): TagColor => {
  return statusColors[(status || 'unknown') as StatusKey]
}

export const getConnectivityLabel = (status: string | undefined, translate: TranslateFn): string => {
  return translate(`cloud.connectivity.${status || 'unknown'}`)
}

export const getConnectivityColor = (status?: string): TagColor => {
  return connectivityColors[status || 'unknown'] || 'default'
}

export const isSpeedTimeoutError = (error?: string): boolean => {
  if (!error) {
    return false
  }

  const normalized = error.toLowerCase()
  return normalized.includes('timeout')
    || normalized.includes('timed out')
    || normalized.includes('deadline exceeded')
}

export const formatSpeedFailureReason = (
  error: string | undefined,
  translate: TranslateFn,
): string => {
  if (!error || error.trim().length === 0) {
    return translate('cloud.speed.failed')
  }

  const normalized = error.trim().toLowerCase()
  if (normalized.includes('sing-box binary not found')) {
    return translate('cloud.speed.reason.coreMissing')
  }
  if (normalized.includes('sing-box socks not ready')) {
    return translate('cloud.speed.reason.socksNotReady')
  }
  if (normalized.includes('no outbounds provided') || normalized.includes('no outbound config')) {
    return translate('cloud.speed.reason.noOutbounds')
  }
  if (isSpeedTimeoutError(error)) {
    return translate('cloud.speed.timeout')
  }

  return error.trim()
}

export const formatPlan = (plan: CloudPlan, translate: TranslateFn): string => {
  if (!plan || typeof plan !== 'object') {
    return String(plan || '')
  }

  const planRecord = plan as Record<string, any>
  const cpuCount = planRecord.vcpu_count ?? planRecord.vcpus ?? plan.vcpus ?? 0
  const ramValue = typeof plan.ram === 'number' && Number.isFinite(plan.ram) ? plan.ram : 0
  const diskValue = typeof plan.disk === 'number' && Number.isFinite(plan.disk) ? plan.disk : 0
  const bandwidthValue = typeof plan.bandwidth === 'number' && Number.isFinite(plan.bandwidth) ? plan.bandwidth : 0

  const ram = ramValue >= 1024 ? `${(ramValue / 1024).toFixed(1)}GB` : `${ramValue}MB`
  const disk = diskValue >= 1024 ? `${(diskValue / 1024).toFixed(1)}TB` : `${diskValue}GB`
  const bandwidth = bandwidthValue >= 1024 ? `${(bandwidthValue / 1024).toFixed(1)}TB` : `${bandwidthValue}GB`

  const meta = [
    `${cpuCount} ${translate('cloud.format.vcpu')}`,
    `${ram} ${translate('cloud.format.ram')}`,
    `${disk} ${translate('cloud.format.disk')}`,
    `${bandwidth} ${translate('cloud.format.bandwidth')}`,
  ]

  if (ramValue > 0) {
    meta.push(
      ramValue <= 600
        ? translate('cloud.format.modeLight')
        : translate('cloud.format.modeFull'),
    )
  }

  const monthlyCost = plan.monthlyCost || planRecord.monthly_cost
  if (monthlyCost && monthlyCost > 0 && Number.isFinite(monthlyCost)) {
    meta.push(`$${monthlyCost.toFixed(2)}${translate('cloud.format.monthly')}`)
  }

  return plan.description ? `${plan.description} · ${meta.join(' · ')}` : `${plan.id} · ${meta.join(' · ')}`
}

export const buildPlanOptions = (
  plans: CloudPlan[],
  availability: Record<string, string[]>,
  currentRegion: string,
  translate: TranslateFn,
): Array<{ label: string; value: string }> => {
  if (!plans.length) {
    return []
  }

  const source = !currentRegion
    ? plans
    : (() => {
        const ids = availability[currentRegion] || []
        if (ids.length > 0) {
          return plans.filter((plan) => ids.includes(plan.id))
        }
        return plans
      })()

  return source.map((plan) => ({
    label: formatPlan(plan, translate),
    value: plan.id,
  }))
}

export const formatNodeRegion = (
  regionId: string,
  regionMap: Map<string, string>,
  translate: TranslateFn,
): string => {
  const idKey = `cloud.regions.${regionId}`
  if (translate(idKey) !== idKey) {
    return translate(idKey)
  }

  const mapped = regionMap.get(regionId)
  if (mapped) {
    return mapped
  }

  return regionId
}

export const buildCloudTableData = (
  instances: ManagedCloudNode[],
  options: TableDataOptions,
): Array<ManagedCloudNode & { id: string }> => {
  let data = instances.map((node) => ({
    ...node,
    id: node.instanceId,
  }))

  if (options.searchQuery.trim()) {
    const query = options.searchQuery.toLowerCase().trim()
    data = data.filter((node) => (
      node.label?.toLowerCase().includes(query) ||
      node.ipv4?.toLowerCase().includes(query) ||
      node.ipv6?.toLowerCase().includes(query) ||
      options.formatNodeRegion(node.region || '').toLowerCase().includes(query) ||
      node.region?.toLowerCase().includes(query)
    ))
  }

  if (options.filterConnectivity !== 'all') {
    data = data.filter((node) => node.connectivityStatus === options.filterConnectivity)
  }

  if (options.filterStatus !== 'all') {
    data = data.filter((node) => node.statusText === options.filterStatus)
  }

  if (options.sortBy) {
    data = [...data].sort((a, b) => {
      let aVal = a[options.sortBy as keyof typeof a]
      let bVal = b[options.sortBy as keyof typeof b]

      if (options.sortBy === 'createdAt') {
        aVal = new Date((aVal as string) || 0).getTime() as never
        bVal = new Date((bVal as string) || 0).getTime() as never
      }

      if (aVal == null) return 1
      if (bVal == null) return -1
      if (aVal < bVal) return options.sortOrder === 'asc' ? -1 : 1
      if (aVal > bVal) return options.sortOrder === 'asc' ? 1 : -1
      return 0
    })
  }

  return data
}
