import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { computed, createApp, defineComponent, nextTick } from 'vue'

const runtimeMocks = vi.hoisted(() => {
  const handlers = new Map<string, (...args: any[]) => void>()
  return {
    handlers,
    EventsOff: vi.fn((event: string) => {
      handlers.delete(event)
    }),
    EventsOn: vi.fn((event: string, callback: (...args: any[]) => void) => {
      handlers.set(event, callback)
      return () => handlers.delete(event)
    }),
  }
})

const utilityMocks = vi.hoisted(() => ({
  checkAllNodesHealth: vi.fn(),
  cleanupOfflineMode: vi.fn(),
  getHealthSummary: vi.fn(),
  initOfflineMode: vi.fn(),
  logInfo: vi.fn(),
  message: {
    error: vi.fn(),
    info: vi.fn(),
  },
  scheduledHealthCheck: undefined as (() => void) | undefined,
  stopHealthChecks: vi.fn(),
  scheduleHealthChecks: vi.fn((callback: () => void) => {
    utilityMocks.scheduledHealthCheck = callback
    return utilityMocks.stopHealthChecks
  }),
}))

vi.mock('@wails/runtime/runtime', () => ({
  EventsOff: runtimeMocks.EventsOff,
  EventsOn: runtimeMocks.EventsOn,
}))

vi.mock('@/utils', () => ({
  message: utilityMocks.message,
}))

vi.mock('@/utils/healthCheck', () => ({
  checkAllNodesHealth: utilityMocks.checkAllNodesHealth,
  getHealthSummary: utilityMocks.getHealthSummary,
  scheduleHealthChecks: utilityMocks.scheduleHealthChecks,
}))

vi.mock('@/utils/logger', () => ({
  logInfo: utilityMocks.logInfo,
}))

vi.mock('@/utils/offline', () => ({
  initOfflineMode: utilityMocks.initOfflineMode,
}))

import { useCloudViewMonitoring } from '../useCloudViewMonitoring'

import type { ManagedCloudNode, NodeHistoryMap } from '@/stores/cloud'
import type { App } from 'vue'

type MountedMonitoring = {
  app: App
  el: HTMLElement
  state: ReturnType<typeof useCloudViewMonitoring>
}

const now = 1_700_000_000_000
const translate = (key: string, params?: Record<string, unknown>) => (
  params ? `${key}:${JSON.stringify(params)}` : key
)

const node = (overrides: Partial<ManagedCloudNode> = {}): ManagedCloudNode => ({
  instanceId: 'node-1',
  label: 'Tokyo edge',
  ipv4: '203.0.113.10',
  connectivityStatus: 'reachable',
  ...overrides,
})

const mountMonitoring = (options: {
  instances?: ManagedCloudNode[]
  nodeHistory?: NodeHistoryMap
  tableRows?: ManagedCloudNode[]
  handleTestAllSpeed?: () => void | Promise<unknown>
  refreshInstances?: (silent?: boolean, force?: boolean) => Promise<unknown>
} = {}): MountedMonitoring => {
  const instances = options.instances ?? [node()]
  const cloudStore = {
    instances,
    nodeHistory: options.nodeHistory ?? {},
    refreshInstances: vi.fn(options.refreshInstances ?? (() => Promise.resolve())),
  }
  const tableRows = options.tableRows ?? instances
  const handleTestAllSpeed = vi.fn(options.handleTestAllSpeed ?? (() => undefined))
  let state!: ReturnType<typeof useCloudViewMonitoring>

  const app = createApp(defineComponent({
    setup() {
      state = useCloudViewMonitoring({
        cloudStore,
        tableData: computed(() => tableRows),
        translate,
        handleTestAllSpeed,
      })
      return () => null
    },
  }))
  const el = document.createElement('div')
  document.body.appendChild(el)
  app.mount(el)

  return { app, el, state }
}

const unmount = ({ app, el }: MountedMonitoring) => {
  app.unmount()
  el.remove()
}

describe('useCloudViewMonitoring', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    runtimeMocks.handlers.clear()
    utilityMocks.scheduledHealthCheck = undefined
    utilityMocks.initOfflineMode.mockReturnValue(utilityMocks.cleanupOfflineMode)
    utilityMocks.getHealthSummary.mockReturnValue({
      total: 1,
      healthy: 0,
      unhealthy: 1,
      avgScore: 40,
      criticalIssues: 1,
    })
    vi.spyOn(Date, 'now').mockReturnValue(now)
  })

  afterEach(() => {
    vi.restoreAllMocks()
    document.body.innerHTML = ''
  })

  it('derives chart data from recent history and node state', async () => {
    const currentNode = node({
      lastConnectivityResult: {
        ip: '203.0.113.10',
        icmpReachable: true,
        portsOpen: {},
        status: 'icmp_blocked',
        targetStatus: {
          hysteria2: 'open',
          unknownProto: 'closed',
        },
      },
      speedMbps: 42,
    })
    const mounted = mountMonitoring({
      instances: [currentNode],
      nodeHistory: {
        'node-1': {
          connectivity: [
            { timestamp: now - 25 * 60 * 60 * 1000, status: 'blocked' },
            { timestamp: now - 1_000, status: 'reachable' },
          ],
          speed: [
            { timestamp: now - 25 * 60 * 60 * 1000, status: 'ok', speedMbps: 5 },
            { timestamp: now - 2_000, status: 'ok', speedMbps: 40 },
            { timestamp: now - 1_000, status: 'partial', speedMbps: 30 },
            { timestamp: now - 500, status: 'timeout' },
          ],
        },
      },
    })

    mounted.state.handleViewCharts(currentNode)
    await nextTick()

    expect(mounted.state.showChartsModal.value).toBe(true)
    expect(mounted.state.connectivityChartData.value).toEqual([
      { timestamp: now - 1_000, status: 'reachable' },
    ])
    expect(mounted.state.latencyChartData.value).toEqual([
      { timestamp: now - 2_000, latency: 40 },
      { timestamp: now - 1_000, latency: 30 },
    ])
    expect(mounted.state.chartCurrentStatusKey.value).toBe('icmp_blocked')
    expect(mounted.state.chartCurrentStatusLabel.value).toBe('cloud.connectivity.icmp_blocked')
    expect(mounted.state.chartLatestSpeedLabel.value).toBe('cloud.speed.mbps:{"speed":42}')
    expect(mounted.state.chartEndpointStatuses.value).toEqual([
      { key: 'hysteria2', label: 'Hysteria2', status: 'open' },
      { key: 'unknownProto', label: 'unknownProto', status: 'closed' },
    ])

    mounted.state.closeChartsModal()
    await nextTick()

    expect(mounted.state.showChartsModal.value).toBe(false)
    expect(mounted.state.viewingChartNode.value).toBeNull()

    unmount(mounted)
  })

  it('formats speed labels from node fields and history fallbacks', async () => {
    const mounted = mountMonitoring({
      nodeHistory: {
        historical: {
          connectivity: [],
          speed: [
            { timestamp: now - 1_000, status: 'error', error: 'sing-box binary not found' },
          ],
        },
      },
    })

    expect(mounted.state.chartLatestSpeedLabel.value).toBe('cloud.charts.noMeasurement')

    const cases: Array<[ManagedCloudNode, string]> = [
      [node({ speedTesting: true }), 'cloud.speed.testing'],
      [node({ speedMbps: 10, speedError: 'partial result' }), 'cloud.speed.mbpsPartial:{"speed":10}'],
      [node({ speedMbps: -1, speedError: 'deadline exceeded' }), 'cloud.speed.timeout'],
      [node({ speedMbps: -1, speedError: 'provider failed' }), 'cloud.speed.failedWithReason:{"reason":"provider failed"}'],
      [node({ speedMs: 128 }), 'cloud.speed.ms:{"ms":128}'],
      [node({ speedMs: -1 }), 'cloud.speed.timeout'],
      [node({ instanceId: 'historical' }), 'cloud.speed.failedWithReason:{"reason":"cloud.speed.reason.coreMissing"}'],
    ]

    for (const [chartNode, label] of cases) {
      mounted.state.handleViewCharts(chartNode)
      await nextTick()
      expect(mounted.state.chartLatestSpeedLabel.value).toBe(label)
    }

    unmount(mounted)
  })

  it('handles keyboard shortcuts and Wails health events', () => {
    const currentNode = node()
    const mounted = mountMonitoring({ instances: [currentNode] })
    const searchInput = document.createElement('input')
    searchInput.placeholder = 'Search nodes'
    document.body.appendChild(searchInput)

    window.dispatchEvent(new KeyboardEvent('keydown', { key: '?' }))
    expect(mounted.state.showKeyboardHelp.value).toBe(true)

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    expect(mounted.state.showKeyboardHelp.value).toBe(false)

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 't', ctrlKey: true }))
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'r', ctrlKey: true }))
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'f', ctrlKey: true }))

    expect(document.activeElement).toBe(searchInput)
    expect(utilityMocks.message.info).toHaveBeenCalledWith('cloud.quickActions.refreshing')

    runtimeMocks.handlers.get('cloud:health:changed')?.('node-1', false, 3)
    expect(currentNode.connectivityStatus).toBe('blocked')
    expect(utilityMocks.logInfo).toHaveBeenCalledWith('[CloudView] Health changed: node-1 unhealthy (3 failures)')

    runtimeMocks.handlers.get('cloud:health:changed')?.('node-1', true, 0)
    expect(currentNode.connectivityStatus).toBe('reachable')

    runtimeMocks.handlers.get('cloud:health:alert')?.('missing-node', 2)
    expect(utilityMocks.message.error).toHaveBeenCalledWith('节点 missing-node 连续 2 次健康检查失败')

    runtimeMocks.handlers.get('cloud:ssh:progress')?.('node-1', 'install', 'done')
    expect(utilityMocks.logInfo).toHaveBeenCalledWith('[SSH Deploy] node-1: [install] done')

    mounted.state.resetSSHDeployProgress()
    unmount(mounted)
  })

  it('schedules health checks and cleans up mounted listeners', () => {
    const currentNode = node()
    const mounted = mountMonitoring({ instances: [currentNode] })

    expect(utilityMocks.initOfflineMode).toHaveBeenCalledTimes(1)
    expect(utilityMocks.scheduleHealthChecks).toHaveBeenCalledWith(expect.any(Function), 5 * 60 * 1000)
    expect(runtimeMocks.EventsOn).toHaveBeenCalledWith('cloud:health:changed', expect.any(Function))
    expect(runtimeMocks.EventsOn).toHaveBeenCalledWith('cloud:health:alert', expect.any(Function))
    expect(runtimeMocks.EventsOn).toHaveBeenCalledWith('cloud:ssh:progress', expect.any(Function))

    utilityMocks.scheduledHealthCheck?.()

    expect(utilityMocks.checkAllNodesHealth).toHaveBeenCalledWith([currentNode])
    expect(utilityMocks.getHealthSummary).toHaveBeenCalled()
    expect(utilityMocks.logInfo).toHaveBeenCalledWith('[CloudView] Health check: 0/1 healthy nodes (avg score: 40)')
    expect(utilityMocks.logInfo).toHaveBeenCalledWith('[CloudView] Warning: 1 nodes have critical health issues')

    unmount(mounted)

    expect(utilityMocks.stopHealthChecks).toHaveBeenCalledTimes(1)
    expect(utilityMocks.cleanupOfflineMode).toHaveBeenCalledTimes(1)
    expect(runtimeMocks.EventsOff).toHaveBeenCalledWith('cloud:health:changed')
    expect(runtimeMocks.EventsOff).toHaveBeenCalledWith('cloud:health:alert')
    expect(runtimeMocks.EventsOff).toHaveBeenCalledWith('cloud:ssh:progress')
  })
})
