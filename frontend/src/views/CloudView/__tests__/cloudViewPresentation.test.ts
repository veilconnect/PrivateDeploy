import { describe, expect, it } from 'vitest'

import {
  buildCloudTableData,
  buildPlanOptions,
  buildRegionOptions,
  formatNodeRegion,
  formatPlan,
  formatRegion,
  formatSpeedFailureReason,
  getConnectivityColor,
  getConnectivityLabel,
  getRiskIcon,
  getRiskLevel,
  getStatusColor,
  getStatusLabel,
  isSpeedTimeoutError,
} from '../cloudViewPresentation'

import type { ManagedCloudNode } from '@/stores/cloud'
import type { CloudPlan, CloudRegion, RegionLatency } from '@/types/cloud'

const dictionary: Record<string, string> = {
  'cloud.regions.Tokyo': 'Tokyo Local',
  'cloud.regions.Japan': 'Japan Local',
  'cloud.regions.nrt': 'Tokyo region',
  'cloud.latency.timeout': 'timeout',
  'cloud.speed.failed': 'failed',
  'cloud.speed.reason.coreMissing': 'core missing',
  'cloud.speed.reason.socksNotReady': 'socks not ready',
  'cloud.speed.reason.noOutbounds': 'no outbounds',
  'cloud.speed.timeout': 'speed timeout',
  'cloud.format.vcpu': 'vCPU',
  'cloud.format.ram': 'RAM',
  'cloud.format.disk': 'disk',
  'cloud.format.bandwidth': 'bandwidth',
  'cloud.format.modeLight': 'light',
  'cloud.format.modeFull': 'full',
  'cloud.format.monthly': '/mo',
  'cloud.status.connected': 'connected',
  'cloud.connectivity.reachable': 'reachable',
}

const translate = (key: string) => dictionary[key] ?? key

const regionLatency = (overrides: Partial<RegionLatency>): RegionLatency => ({
  code: 'nrt',
  name: 'Tokyo',
  ip: '203.0.113.1',
  latency: 100,
  loss: 0,
  status: 'ok',
  ...overrides,
})

const plan = (overrides: Partial<CloudPlan>): CloudPlan => ({
  id: 'vc2-1c-1gb',
  ram: 1024,
  vcpus: 1,
  disk: 25,
  bandwidth: 1024,
  ...overrides,
})

const node = (overrides: Partial<ManagedCloudNode>): ManagedCloudNode => ({
  instanceId: 'node-1',
  label: 'Tokyo edge',
  region: 'nrt',
  ipv4: '203.0.113.10',
  connectivityStatus: 'reachable',
  statusText: 'connected',
  createdAt: '2026-01-01T00:00:00.000Z',
  ...overrides,
})

describe('cloud view presentation helpers', () => {
  it('formats and sorts regions by risk, timeout status, and latency', () => {
    const regions: CloudRegion[] = [
      { id: 'ewr', city: 'Newark', country: 'United States' },
      { id: 'sgp', city: 'Singapore', country: 'Singapore' },
      { id: 'nrt', city: 'Tokyo', country: 'Japan' },
      { id: 'fra', city: 'Frankfurt', country: 'Germany' },
    ]

    expect(getRiskLevel('nrt')).toBe('low')
    expect(getRiskLevel('unknown-region')).toBe('medium')
    expect(getRiskIcon('critical')).toBe('🔴')
    expect(formatRegion(regions[2], 'vultr', translate)).toBe('Tokyo Local, Japan Local')
    expect(formatRegion(regions[2], 'digitalocean', translate)).toBe('Tokyo')

    expect(buildRegionOptions(regions, [
      regionLatency({ code: 'ewr', latency: 10 }),
      regionLatency({ code: 'sgp', latency: 20, status: 'timeout' }),
      regionLatency({ code: 'nrt', latency: 100 }),
      regionLatency({ code: 'fra', latency: 40 }),
    ], 'vultr', translate).map((option) => option.value)).toEqual(['nrt', 'sgp', 'fra', 'ewr'])
  })

  it('formats status, connectivity, and speed failure labels', () => {
    expect(getStatusLabel('connected', translate)).toBe('connected')
    expect(getStatusColor('applying')).toBe('cyan')
    expect(getStatusColor('unexpected')).toBeUndefined()
    expect(getConnectivityLabel('reachable', translate)).toBe('reachable')
    expect(getConnectivityColor('icmp_blocked')).toBe('cyan')
    expect(getConnectivityColor('unexpected')).toBe('default')

    expect(isSpeedTimeoutError('deadline exceeded')).toBe(true)
    expect(isSpeedTimeoutError('connection refused')).toBe(false)
    expect(formatSpeedFailureReason('', translate)).toBe('failed')
    expect(formatSpeedFailureReason('sing-box binary not found', translate)).toBe('core missing')
    expect(formatSpeedFailureReason('sing-box socks not ready', translate)).toBe('socks not ready')
    expect(formatSpeedFailureReason('no outbound config', translate)).toBe('no outbounds')
    expect(formatSpeedFailureReason('timed out while testing', translate)).toBe('speed timeout')
    expect(formatSpeedFailureReason(' provider failed ', translate)).toBe('provider failed')
  })

  it('formats plan labels and filters options by region availability', () => {
    expect(formatPlan(plan({
      description: 'Basic plan',
      monthlyCost: 5,
    }), translate)).toContain('Basic plan')
    expect(formatPlan(plan({
      id: 'tiny',
      ram: 512,
      disk: 2048,
      bandwidth: 512,
    }), translate)).toContain('512MB RAM')
    expect(formatPlan(null as unknown as CloudPlan, translate)).toBe('')

    expect(buildPlanOptions([
      plan({ id: 'small' }),
      plan({ id: 'large', ram: 2048 }),
    ], { nrt: ['large'] }, 'nrt', translate).map((option) => option.value)).toEqual(['large'])
    expect(buildPlanOptions([plan({ id: 'small' })], {}, 'nrt', translate)).toHaveLength(1)
    expect(buildPlanOptions([], {}, 'nrt', translate)).toEqual([])
  })

  it('formats node regions and builds filtered, sorted table data', () => {
    const regionMap = new Map([['sgp', 'Singapore mapped']])
    expect(formatNodeRegion('nrt', regionMap, translate)).toBe('Tokyo region')
    expect(formatNodeRegion('sgp', regionMap, translate)).toBe('Singapore mapped')
    expect(formatNodeRegion('fra', regionMap, translate)).toBe('fra')

    const data = buildCloudTableData([
      node({ instanceId: 'old', label: 'Singapore edge', region: 'sgp', createdAt: '2026-01-01T00:00:00.000Z' }),
      node({ instanceId: 'new', label: 'Tokyo edge', region: 'nrt', createdAt: '2026-02-01T00:00:00.000Z' }),
      node({ instanceId: 'blocked', label: 'Frankfurt edge', region: 'fra', connectivityStatus: 'blocked' }),
    ], {
      searchQuery: 'tokyo',
      filterConnectivity: 'reachable',
      filterStatus: 'connected',
      sortBy: 'createdAt',
      sortOrder: 'desc',
      formatNodeRegion: (regionId) => formatNodeRegion(regionId, regionMap, translate),
    })

    expect(data).toEqual([
      expect.objectContaining({ id: 'new', instanceId: 'new' }),
    ])

    expect(buildCloudTableData([
      node({ instanceId: 'b', label: 'B', createdAt: '2026-01-02T00:00:00.000Z' }),
      node({ instanceId: 'a', label: 'A', createdAt: '2026-01-01T00:00:00.000Z' }),
    ], {
      searchQuery: '',
      filterConnectivity: 'all',
      filterStatus: 'all',
      sortBy: 'createdAt',
      sortOrder: 'asc',
      formatNodeRegion: translate,
    }).map((item) => item.instanceId)).toEqual(['a', 'b'])
  })
})
