import { beforeEach, describe, expect, it, vi } from 'vitest'
import { ref } from 'vue'

const bridgeMocks = vi.hoisted(() => ({
  ClipboardSetText: vi.fn(),
}))

const cdnMocks = vi.hoisted(() => ({
  store: {
    deploy: vi.fn(),
    deploymentFor: vi.fn(),
    isVerified: true,
    lastError: '',
    remove: vi.fn(),
  },
  useCdnStore: vi.fn(),
}))

const utilityMocks = vi.hoisted(() => ({
  confirm: vi.fn(),
  getRecommendedNodes: vi.fn(),
  logError: vi.fn(),
  logInfo: vi.fn(),
  message: {
    error: vi.fn(),
    info: vi.fn(),
    success: vi.fn(),
  },
}))

vi.mock('@/bridge', () => ({
  ClipboardSetText: bridgeMocks.ClipboardSetText,
}))

vi.mock('@/stores', () => ({
  useCdnStore: cdnMocks.useCdnStore,
}))

vi.mock('@/utils', () => ({
  confirm: utilityMocks.confirm,
  message: utilityMocks.message,
}))

vi.mock('@/utils/logger', () => ({
  logError: utilityMocks.logError,
  logInfo: utilityMocks.logInfo,
}))

vi.mock('@/utils/recommendation', () => ({
  getRecommendedNodes: utilityMocks.getRecommendedNodes,
}))

import { useCloudViewActions } from '../useCloudViewActions'

import type { ManagedCloudNode } from '@/stores/cloud'
import type { CloudNode, RegionLatency } from '@/types/cloud'

const translate = (key: string, params?: Record<string, unknown>) => (
  params ? `${key}:${JSON.stringify(params)}` : key
)

const node = (overrides: Partial<ManagedCloudNode> = {}): ManagedCloudNode => ({
  instanceId: 'node-1',
  label: 'Tokyo edge',
  provider: 'vultr',
  region: 'nrt',
  ipv4: '203.0.113.10',
  connectivityStatus: 'reachable',
  ssPort: 8388,
  ssPassword: 'secret',
  ...overrides,
})

const createHarness = (options: {
  instances?: ManagedCloudNode[]
  latencyResults?: RegionLatency[]
  loadBalanceEnabled?: boolean
  kernelRunning?: boolean
} = {}) => {
  const cloudStore = {
    instances: options.instances ?? [node()],
    loadBalanceEnabled: options.loadBalanceEnabled ?? false,
    markNodeStatus: vi.fn(),
    applyNodeToProfile: vi.fn<(_: CloudNode) => Promise<unknown>>().mockResolvedValue(undefined),
    refreshInstances: vi.fn<(_: boolean, __?: boolean) => Promise<unknown>>().mockResolvedValue(undefined),
    rotateIP: vi.fn<(_: string) => Promise<{ instanceId: string }>>()
      .mockResolvedValue({ instanceId: 'rotated-node' }),
    redeployInstance: vi.fn<(_: string) => Promise<{ instanceId: string }>>()
      .mockResolvedValue({ instanceId: 'redeployed-node' }),
    destroyInstance: vi.fn<(_: string) => Promise<unknown>>().mockResolvedValue(undefined),
    testNodeSpeedTest: vi.fn<(_: string) => Promise<unknown>>().mockResolvedValue(undefined),
    testAllNodesSpeed: vi.fn<() => Promise<unknown>>().mockResolvedValue(undefined),
    startLoadBalance: vi.fn<() => Promise<unknown>>().mockResolvedValue(undefined),
    stopLoadBalance: vi.fn<() => Promise<unknown>>().mockResolvedValue(undefined),
  }
  const kernelApiStore = {
    running: options.kernelRunning ?? false,
    restartCore: vi.fn<() => Promise<unknown>>().mockResolvedValue(undefined),
    startCore: vi.fn<() => Promise<unknown>>().mockResolvedValue(undefined),
  }
  const handleError = vi.fn()
  const actions = useCloudViewActions({
    cloudStore,
    kernelApiStore,
    latencyResults: ref(options.latencyResults ?? []),
    translate,
    handleError,
    formatNodeRegion: (regionId) => `region:${regionId}`,
    isManualNode: (record) => (record as ManagedCloudNode).provider === 'manual',
  })

  return {
    actions,
    cloudStore,
    handleError,
    kernelApiStore,
  }
}

describe('useCloudViewActions', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    cdnMocks.store.isVerified = true
    cdnMocks.store.lastError = ''
    cdnMocks.store.deploy.mockResolvedValue(true)
    cdnMocks.store.deploymentFor.mockReturnValue(null)
    cdnMocks.store.remove.mockResolvedValue(true)
    cdnMocks.useCdnStore.mockReturnValue(cdnMocks.store)
    bridgeMocks.ClipboardSetText.mockResolvedValue(undefined)
    utilityMocks.confirm.mockResolvedValue(true)
    utilityMocks.getRecommendedNodes.mockReturnValue([])
  })

  it('manages selection and batch connectivity tests', async () => {
    const harness = createHarness({
      instances: [
        node({ instanceId: 'node-1' }),
        node({ instanceId: 'node-2' }),
      ],
    })

    await harness.actions.handleBatchTestConnectivity()
    expect(utilityMocks.message.info).toHaveBeenCalledWith('cloud.batch.noSelection')

    harness.actions.toggleNodeSelection('node-1')
    harness.actions.toggleNodeSelection('node-2')
    expect([...harness.actions.selectedNodeIds.value]).toEqual(['node-1', 'node-2'])

    await harness.actions.handleBatchTestConnectivity()

    expect(harness.cloudStore.testNodeSpeedTest).toHaveBeenCalledWith('node-1')
    expect(harness.cloudStore.testNodeSpeedTest).toHaveBeenCalledWith('node-2')
    expect(utilityMocks.message.success).toHaveBeenCalledWith('cloud.batch.testComplete:{"count":2}')
    expect(harness.actions.batchOperating.value).toBe(false)

    harness.actions.toggleNodeSelection('node-1')
    expect([...harness.actions.selectedNodeIds.value]).toEqual(['node-2'])
    harness.actions.clearSelection()
    expect(harness.actions.selectedNodeIds.value.size).toBe(0)
  })

  it('rotates and destroys selected nodes with partial failure reporting', async () => {
    const harness = createHarness()
    harness.actions.toggleNodeSelection('node-1')
    harness.actions.toggleNodeSelection('node-2')
    harness.cloudStore.rotateIP.mockRejectedValueOnce(new Error('rotate failed'))

    await harness.actions.handleBatchRotateIP()

    expect(utilityMocks.confirm).toHaveBeenCalledWith(
      'cloud.batch.rotateIP',
      'cloud.batch.rotateConfirm:{"count":2}',
    )
    expect(utilityMocks.logError).toHaveBeenCalledWith(
      '[CloudView] Failed to rotate IP for node-1:',
      expect.any(Error),
    )
    expect(utilityMocks.message.success).toHaveBeenCalledWith('cloud.batch.rotateComplete:{"success":1,"fail":1}')
    expect(harness.cloudStore.refreshInstances).toHaveBeenCalledWith(true)
    expect(harness.actions.selectedNodeIds.value.size).toBe(0)

    harness.actions.toggleNodeSelection('node-1')
    harness.cloudStore.destroyInstance.mockRejectedValueOnce(new Error('destroy failed'))
    await harness.actions.handleBatchDestroy()

    expect(utilityMocks.message.error).toHaveBeenCalledWith('cloud.batch.allFailed')
    expect(harness.actions.batchOperating.value).toBe(false)
  })

  it('applies nodes to the active profile and starts or restarts the core', async () => {
    const stopped = createHarness({ kernelRunning: false })

    await stopped.actions.handleUseNode(node())

    expect(stopped.cloudStore.markNodeStatus).toHaveBeenCalledWith('node-1', 'applying')
    expect(stopped.cloudStore.applyNodeToProfile).toHaveBeenCalledWith(expect.objectContaining({ instanceId: 'node-1' }))
    expect(stopped.kernelApiStore.startCore).toHaveBeenCalledTimes(1)
    expect(stopped.cloudStore.markNodeStatus).toHaveBeenCalledWith('node-1', 'connected')
    expect(utilityMocks.message.success).toHaveBeenCalledWith('cloud.nodes.applied')
    expect(stopped.actions.applyingNodeId.value).toBe('')

    const running = createHarness({ kernelRunning: true })
    running.cloudStore.applyNodeToProfile.mockRejectedValueOnce(new Error('apply failed'))

    await running.actions.handleUseNode(node())

    expect(running.kernelApiStore.restartCore).not.toHaveBeenCalled()
    expect(running.cloudStore.markNodeStatus).toHaveBeenCalledWith('node-1', 'error')
    expect(running.handleError).toHaveBeenCalledWith(expect.any(Error))
  })

  it('copies protocol links and handles CDN deployment lifecycle', async () => {
    const harness = createHarness()
    const relayNode = node({
      vlessRelayPort: 10000,
      vlessUUID: '11111111-1111-4111-8111-111111111111',
    })

    await harness.actions.copyNodeConfig(relayNode)

    expect(bridgeMocks.ClipboardSetText).toHaveBeenCalledWith(expect.stringContaining('Shadowsocks: ss://'))
    expect(utilityMocks.message.success).toHaveBeenCalledWith('common.copied')

    await harness.actions.copyNodeConfig(node({ ssPort: undefined, ssPassword: undefined }))
    expect(utilityMocks.message.error).toHaveBeenCalledWith('cloud.errors.noProtocols')

    await harness.actions.handleDeployCdn(node())
    expect(utilityMocks.message.error).toHaveBeenCalledWith('cdn.node.requiresRelay')

    cdnMocks.store.isVerified = false
    await harness.actions.handleDeployCdn(relayNode)
    expect(utilityMocks.message.error).toHaveBeenCalledWith('cdn.error.tokenNotVerified')

    cdnMocks.store.isVerified = true
    await harness.actions.handleDeployCdn(relayNode)
    expect(cdnMocks.store.deploy).toHaveBeenCalledWith('node-1')
    expect(utilityMocks.message.success).toHaveBeenCalledWith('common.success')

    cdnMocks.store.deploy.mockResolvedValueOnce(false)
    cdnMocks.store.lastError = 'deploy failed'
    await harness.actions.handleDeployCdn(relayNode)
    expect(utilityMocks.message.error).toHaveBeenCalledWith('deploy failed')

    await harness.actions.handleDeleteCdn(relayNode)
    expect(cdnMocks.store.remove).toHaveBeenCalledWith('node-1')
    expect(utilityMocks.message.success).toHaveBeenCalledWith('common.success')
  })

  it('handles single-node rotate and destroy actions', async () => {
    const harness = createHarness()

    await harness.actions.handleRotateIP(node({ provider: 'manual' }))
    expect(utilityMocks.message.error).toHaveBeenCalledWith('cloud.nodes.rotateIPBlocked')

    await harness.actions.handleRotateIP(node())
    expect(harness.cloudStore.rotateIP).toHaveBeenCalledWith('node-1')
    expect(utilityMocks.logInfo).toHaveBeenCalledWith(
      '[CloudView] IP rotated successfully. New node:',
      'rotated-node',
    )
    expect(harness.actions.rotatingNodeId.value).toBe('')

    utilityMocks.confirm.mockRejectedValueOnce(new Error('cancel'))
    await harness.actions.handleDestroy(node())
    expect(harness.cloudStore.destroyInstance).not.toHaveBeenCalled()

    await harness.actions.handleDestroy(node())
    expect(harness.cloudStore.destroyInstance).toHaveBeenCalledWith('node-1')
    expect(utilityMocks.message.success).toHaveBeenCalledWith('common.success')
  })

  it('supports recommendations, quick menu actions, and load balancing', async () => {
    const recommendedNode = node({ instanceId: 'best', label: 'Best node' })
    utilityMocks.getRecommendedNodes.mockReturnValueOnce([
      {
        resilienceScore: 95,
        node: recommendedNode,
        reasons: ['reachable', 'low latency'],
        score: 98,
      },
    ])
    const harness = createHarness({
      instances: [recommendedNode],
      latencyResults: [
        { code: 'nrt', name: 'Tokyo', ip: '203.0.113.1', latency: 42, loss: 0, status: 'ok' },
      ],
    })

    harness.actions.handleShowRecommendations()
    expect(utilityMocks.getRecommendedNodes).toHaveBeenCalledWith(
      [recommendedNode],
      expect.objectContaining({ preferLowLatency: true, preferReachable: true }),
      new Map([['nrt', 42]]),
    )
    expect(utilityMocks.logInfo).toHaveBeenCalledWith(expect.stringContaining('Best node'))

    const menu = harness.actions.tableContextMenu.value
    expect(menu.map((item) => item.label)).toEqual([
      'cloud.quickActions.useNode',
      'cloud.quickActions.copyConfig',
      'cloud.quickActions.testConnectivity',
      'cloud.quickActions.rotateIP',
      'cloud.quickActions.repair',
      'cdn.node.deploy',
      'cdn.node.delete',
      'cloud.quickActions.destroy',
    ])
    expect(menu[3].hidden?.(node({ connectivityStatus: 'reachable' }))).toBe(true)
    expect(menu[3].hidden?.(node({ connectivityStatus: 'blocked' }))).toBe(false)
    expect(menu[4].hidden?.(node({ provider: 'manual' }))).toBe(true)
    expect(menu[4].hidden?.(node())).toBe(false)

    await menu[1].handler(node({ speedMs: 88 }))
    expect(bridgeMocks.ClipboardSetText).toHaveBeenCalledWith(expect.stringContaining('Node: Tokyo edge'))

    await menu[2].handler(node({ speedMs: 88 }))
    expect(harness.cloudStore.testNodeSpeedTest).toHaveBeenCalledWith('node-1')
    expect(utilityMocks.message.success).toHaveBeenCalledWith('cloud.quickActions.testComplete:{"status":"88ms"}')

    await menu[4].handler(node())
    expect(harness.cloudStore.redeployInstance).toHaveBeenCalledWith('node-1')
    expect(utilityMocks.message.success).toHaveBeenCalledWith('cloud.nodes.redeploySuccess')

    await harness.actions.handleTestAllSpeed()
    expect(harness.cloudStore.testAllNodesSpeed).toHaveBeenCalledTimes(1)
    expect(harness.actions.speedTestAllLoading.value).toBe(false)

    await harness.actions.handleToggleLoadBalance()
    expect(harness.cloudStore.startLoadBalance).toHaveBeenCalledTimes(1)
    expect(utilityMocks.message.error).toHaveBeenCalledWith('cloud.loadBalance.startFailed')

    const enabled = createHarness({ loadBalanceEnabled: true })
    await enabled.actions.handleToggleLoadBalance()
    expect(enabled.cloudStore.stopLoadBalance).toHaveBeenCalledTimes(1)
    expect(enabled.actions.loadBalanceLoading.value).toBe(false)
  })
})
