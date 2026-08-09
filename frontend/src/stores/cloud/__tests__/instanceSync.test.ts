import { beforeEach, describe, expect, it, vi } from 'vitest'
import { ref, shallowRef } from 'vue'

const mocks = vi.hoisted(() => ({
  listCloudInstances: vi.fn(),
  createCloudInstance: vi.fn(),
  cancelCloudOperation: vi.fn(),
  getCloudOperationStatus: vi.fn(),
  listPendingCloudOperations: vi.fn(),
  createMultipleCloudInstances: vi.fn(),
  destroyCloudInstance: vi.fn(),
  repairCloudInstance: vi.fn(),
  testConnectivity: vi.fn(),
  testNodeDirectSpeed: vi.fn(),
  readFile: vi.fn(),
  retryWithBackoff: vi.fn((fn: () => Promise<unknown>) => fn()),
  isOnline: { value: true },
  saveToOfflineCache: vi.fn(),
  loadFromOfflineCache: vi.fn(),
  notifications: {
    deploymentComplete: vi.fn(),
    deploymentFailed: vi.fn(),
    connectivityBlocked: vi.fn(),
    connectivityRestored: vi.fn(),
    error: vi.fn(),
    info: vi.fn(),
    rotationComplete: vi.fn(),
    rotationFailed: vi.fn(),
  },
}))

vi.mock('@/bridge', () => ({
  ListCloudInstances: mocks.listCloudInstances,
  CreateCloudInstance: mocks.createCloudInstance,
  CancelCloudOperation: mocks.cancelCloudOperation,
  GetCloudOperationStatus: mocks.getCloudOperationStatus,
  ListPendingCloudOperations: mocks.listPendingCloudOperations,
  CreateMultipleCloudInstances: mocks.createMultipleCloudInstances,
  DestroyCloudInstance: mocks.destroyCloudInstance,
  RepairCloudInstance: mocks.repairCloudInstance,
  TestConnectivity: mocks.testConnectivity,
  TestNodeDirectSpeed: mocks.testNodeDirectSpeed,
  ReadFile: mocks.readFile,
}))

vi.mock('@/utils/errorRecovery', () => ({
  retryWithBackoff: mocks.retryWithBackoff,
}))

vi.mock('@/utils/logger', () => ({
  logError: vi.fn(),
  logInfo: vi.fn(),
}))

vi.mock('@/utils/notification', () => ({
  notifications: mocks.notifications,
}))

vi.mock('@/utils/offline', () => ({
  isOnline: mocks.isOnline,
  saveToOfflineCache: mocks.saveToOfflineCache,
  loadFromOfflineCache: mocks.loadFromOfflineCache,
}))

import { Outbound } from '@/enums/kernel'

import { subscriptionId } from '../helpers'
import { createInstanceSync } from '../instanceSync'

import type { ManagedCloudNode } from '../types'
import type { CloudProvider } from '@/types/cloud'

const readyNode = (overrides: Partial<ManagedCloudNode> = {}): ManagedCloudNode => ({
  instanceId: 'node-1',
  label: 'Tokyo',
  provider: 'vultr',
  status: 'active',
  statusText: 'connected',
  region: 'nrt',
  plan: 'vc2-1c-1gb',
  ipv4: '203.0.113.10',
  ssPort: 8388,
  ssPassword: 'secret',
  ...overrides,
} as ManagedCloudNode)

const profileWithCloudSubscription = (instanceId = 'node-1'): IProfile => ({
  id: 'profile-1',
  name: 'Managed',
  log: {},
  experimental: {},
  inbounds: [],
  outbounds: [
    {
      id: 'selector',
      tag: 'Proxy',
      type: Outbound.Selector,
      outbounds: [{ id: subscriptionId(instanceId), tag: 'Tokyo', type: 'Subscription' }],
    } as IOutbound,
  ],
  route: {
    rules: [],
    rule_set: [],
    final: 'selector',
    auto_detect_interface: false,
    default_interface: '',
    find_process: false,
  },
  dns: {},
  mixin: {},
  script: [],
})

const createHarness = (options: {
  instances?: ManagedCloudNode[]
  manualNodes?: ManagedCloudNode[]
  profile?: IProfile
  running?: boolean
} = {}) => {
  const instances = shallowRef<ManagedCloudNode[]>(options.instances ?? [])
  const manualNodes = shallowRef<ManagedCloudNode[]>(options.manualNodes ?? [])
  const instancesUpdatedAt = ref<number | null>(null)
  const loadingInstances = ref(false)
  const creatingInstance = ref(false)
  const destroyingInstance = ref('')
  const currentProvider = ref<CloudProvider>('vultr')
  const recordConnectivitySample = vi.fn().mockResolvedValue(undefined)
  const recordSpeedSample = vi.fn().mockResolvedValue(undefined)
  const syncManualNodesIntoInstances = vi.fn()
  const saveManualNodes = vi.fn().mockResolvedValue(undefined)
  const ensureSubscriptionForNode = vi.fn().mockResolvedValue(undefined)
  const removeSubscriptionForNode = vi.fn().mockResolvedValue(undefined)
  const applyNodeToProfile = vi.fn().mockResolvedValue('profile-1')
  const applyAllNodesToProfile = vi.fn().mockResolvedValue([])
  const reloadKernel = vi.fn().mockResolvedValue(undefined)
  const ensureRegionAvailability = vi.fn().mockResolvedValue([])

  const api = createInstanceSync({
    config: { apiKey: 'token' },
    currentProvider,
    instances,
    instancesUpdatedAt,
    loadingInstances,
    creatingInstance,
    destroyingInstance,
    manualNodes,
    latencyTestResults: ref({}),
    latencyUpdatedAt: ref(null),
    multiDeployProgress: ref(new Map()),
    appSettingsStore: {
      app: {
        kernel: { profile: options.profile?.id ?? '' },
        autoStartKernel: true,
      },
    },
    profilesStore: {
      getProfileById: () => options.profile,
    },
    kernelApiStore: {
      running: options.running ?? false,
      config: {},
      proxies: {},
      refreshProviderProxies: vi.fn().mockResolvedValue(undefined),
      addCloudNodeToGroups: vi.fn(),
      getProxyPort: vi.fn(),
    },
    subscribesStore: {
      subscribes: [{ id: subscriptionId('node-1') }],
    },
    ensureSubscriptionForNode,
    removeSubscriptionForNode,
    migrateManagedNodeIdentity: vi.fn().mockResolvedValue(false),
    applyNodeToProfile,
    applyAllNodesToProfile,
    loadNodeHistory: vi.fn().mockResolvedValue(undefined),
    migrateNodeHistory: vi.fn().mockResolvedValue(false),
    recordConnectivitySample,
    recordSpeedSample,
    loadManualNodes: vi.fn().mockResolvedValue(manualNodes.value),
    syncManualNodesIntoInstances,
    saveManualNodes,
    ensureRegionAvailability,
    updateProtocolHealthFromConnectivity: vi.fn().mockResolvedValue(undefined),
    reloadKernel,
    markNodeStatus: vi.fn(),
  })

  return {
    api,
    instances,
    manualNodes,
    instancesUpdatedAt,
    loadingInstances,
    creatingInstance,
    destroyingInstance,
    currentProvider,
    ensureSubscriptionForNode,
    removeSubscriptionForNode,
    applyNodeToProfile,
    applyAllNodesToProfile,
    syncManualNodesIntoInstances,
    saveManualNodes,
    recordConnectivitySample,
    recordSpeedSample,
    reloadKernel,
    ensureRegionAvailability,
  }
}

describe('createInstanceSync', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.spyOn(Date, 'now').mockReturnValue(1_700_000_000_000)
    mocks.isOnline.value = true
    mocks.loadFromOfflineCache.mockReturnValue(null)
    mocks.listCloudInstances.mockResolvedValue([readyNode()])
    mocks.cancelCloudOperation.mockResolvedValue(undefined)
    mocks.getCloudOperationStatus.mockResolvedValue({ state: 'running' })
    mocks.listPendingCloudOperations.mockResolvedValue([])
    mocks.testConnectivity.mockResolvedValue({
      status: 'reachable',
      targetStatus: { 'shadowsocks-tcp': 'open' },
      portsOpen: { 8388: true },
    })
    mocks.testNodeDirectSpeed.mockResolvedValue({
      status: 'ok',
      speedMbps: 12.345,
    })
    mocks.readFile.mockResolvedValue(JSON.stringify({
      outbounds: [{ tag: 'Tokyo-ss-v4', type: 'shadowsocks' }],
    }))
  })

  it('refreshes provider instances, persists cache, creates subscriptions, and syncs manual nodes', async () => {
    const harness = createHarness({
      profile: profileWithCloudSubscription(),
    })

    await harness.api.refreshInstances(false, true)

    expect(mocks.listCloudInstances).toHaveBeenCalledTimes(1)
    expect(harness.instances.value).toEqual([
      expect.objectContaining({
        instanceId: 'node-1',
        provider: 'vultr',
        statusText: 'connected',
      }),
    ])
    expect(mocks.saveToOfflineCache).toHaveBeenCalledWith('nodes', harness.instances.value)
    expect(harness.ensureSubscriptionForNode).toHaveBeenCalledWith(
      expect.objectContaining({ instanceId: 'node-1' }),
    )
    expect(harness.applyAllNodesToProfile).toHaveBeenCalledTimes(1)
    expect(harness.syncManualNodesIntoInstances).toHaveBeenCalled()
    expect(harness.loadingInstances.value).toBe(false)
  })

  it('uses offline cached instances without calling the provider API', async () => {
    const cached = [readyNode({ instanceId: 'cached-node', label: 'Cached' })]
    mocks.isOnline.value = false
    mocks.loadFromOfflineCache.mockReturnValue(cached)
    const harness = createHarness()

    await harness.api.refreshInstances()

    expect(mocks.listCloudInstances).not.toHaveBeenCalled()
    expect(harness.instances.value).toBe(cached)
    expect(harness.instancesUpdatedAt.value).toBeTypeOf('number')
    expect(harness.syncManualNodesIntoInstances).toHaveBeenCalled()
  })

  it('destroys manual nodes locally without calling the cloud provider', async () => {
    const manual = readyNode({ instanceId: 'manual-1', provider: 'manual' })
    const harness = createHarness({
      instances: [manual],
      manualNodes: [manual],
    })

    await harness.api.destroyInstance('manual-1')

    expect(mocks.destroyCloudInstance).not.toHaveBeenCalled()
    expect(harness.manualNodes.value).toEqual([])
    expect(harness.instances.value).toEqual([])
    expect(harness.saveManualNodes).toHaveBeenCalledTimes(1)
    expect(harness.removeSubscriptionForNode).toHaveBeenCalledWith('manual-1')
    expect(harness.destroyingInstance.value).toBe('')
  })

  it('repairs a cloud node in place, refreshes its subscription, and clears a resolved warning', async () => {
    mocks.repairCloudInstance.mockResolvedValue(
      readyNode({ instanceId: 'node-1', lastDeployWarning: '' }),
    )
    const harness = createHarness({
      instances: [readyNode({ lastDeployWarning: 'service readiness failed: timeout' })],
    })

    const result = await harness.api.redeployInstance('node-1')

    expect(mocks.repairCloudInstance).toHaveBeenCalledWith('node-1')
    expect(result.instanceId).toBe('node-1')
    expect(harness.instances.value.map((item) => item.instanceId)).toEqual(['node-1'])
    expect(harness.instances.value[0]).toMatchObject({
      statusText: 'connected',
      lastDeployWarning: '',
    })
    expect(harness.ensureSubscriptionForNode).toHaveBeenCalledWith(
      expect.objectContaining({ instanceId: 'node-1' }),
    )
    expect(harness.applyNodeToProfile).toHaveBeenCalledWith(
      expect.objectContaining({ instanceId: 'node-1' }),
    )
    expect(harness.reloadKernel).toHaveBeenCalledWith('repair-instance')
  })

  it('never deletes an unproven server returned by an invalid repair response', async () => {
    mocks.repairCloudInstance.mockResolvedValue(
      readyNode({ instanceId: 'node-2', label: 'Unexpected replacement' }),
    )
    const harness = createHarness({ instances: [readyNode()] })

    await expect(harness.api.redeployInstance('node-1')).rejects.toThrow(
      'Repair returned unexpected server node-2',
    )

    expect(mocks.destroyCloudInstance).not.toHaveBeenCalled()
    expect(harness.instances.value.map((item) => item.instanceId)).toEqual(['node-1'])
    expect(harness.ensureSubscriptionForNode).not.toHaveBeenCalledWith(
      expect.objectContaining({ instanceId: 'node-2' }),
    )
  })

  it('records connectivity probes and updates protocol health', async () => {
    const harness = createHarness({
      instances: [readyNode()],
    })
    const originalNode = harness.instances.value[0]

    await harness.api.testNodeConnectivity('node-1')

    expect(mocks.testConnectivity).toHaveBeenCalledWith(
      '203.0.113.10',
      expect.objectContaining({
        tcpPorts: [8388],
        udpPorts: [8388],
        targets: expect.arrayContaining([
          { name: 'shadowsocks-tcp', port: 8388, network: 'tcp' },
          { name: 'shadowsocks-udp', port: 8388, network: 'udp' },
        ]),
      }),
    )
    expect(harness.instances.value[0]).toMatchObject({
      connectivityStatus: 'reachable',
      connectivityTesting: false,
    })
    expect(harness.instances.value[0]).not.toBe(originalNode)
    expect(harness.recordConnectivitySample).toHaveBeenCalledWith(
      'node-1',
      'reachable',
      expect.objectContaining({ status: 'reachable' }),
    )
    expect(mocks.notifications.connectivityRestored).toHaveBeenCalledWith('Tokyo')
  })

  it('reads subscription outbounds and records rounded speed samples', async () => {
    const harness = createHarness({
      instances: [readyNode()],
    })

    await harness.api.testNodeSpeedTest('node-1')

    expect(mocks.readFile).toHaveBeenCalledWith('data/subscribes/cloud-node-1.json')
    expect(mocks.testNodeDirectSpeed).toHaveBeenCalledWith(
      [{ tag: 'Tokyo-ss-v4', type: 'shadowsocks' }],
      15,
    )
    expect(harness.instances.value[0]).toMatchObject({
      speedMbps: 12.35,
      speedTesting: false,
    })
    expect(harness.recordSpeedSample).toHaveBeenCalledWith('node-1', {
      speedMbps: 12.35,
      status: 'ok',
      error: undefined,
    })
  })

  it('shows a deploying placeholder immediately and replaces it once CreateCloudInstance resolves', async () => {
    let resolveCreate: (value: unknown) => void = () => {}
    mocks.createCloudInstance.mockImplementation(
      () => new Promise((resolve) => { resolveCreate = resolve }),
    )
    const harness = createHarness()

    const pending = harness.api.createInstance({ label: 'New LAX', region: 'lax', plan: 'vc2-1c-1gb' })

    // Before CreateCloudInstance (which blocks for minutes server-side) has
    // resolved at all, the node must already be visible in the list.
    expect(harness.instances.value).toHaveLength(1)
    expect(harness.instances.value[0]).toMatchObject({
      label: 'New LAX',
      region: 'lax',
      plan: 'vc2-1c-1gb',
      statusText: 'deploying',
      deploymentState: 'submitting',
      deploymentStartedAt: 1_700_000_000_000,
    })
    expect(mocks.createCloudInstance).toHaveBeenCalledWith(expect.objectContaining({
      label: 'New LAX',
      region: 'lax',
      plan: 'vc2-1c-1gb',
      operationId: expect.any(String),
    }))

    resolveCreate({
      instanceId: 'node-new',
      label: 'New LAX',
      region: 'lax',
      plan: 'vc2-1c-1gb',
      ipv4: '1.2.3.4',
      ssPort: 8388,
      ssPassword: 'secret',
    })
    await pending

    expect(harness.instances.value.some((n) => n.statusText === 'deploying')).toBe(false)
    expect(harness.instances.value.some((n) => n.instanceId === 'node-new')).toBe(true)
    expect(mocks.createCloudInstance).toHaveBeenCalledTimes(1)
    expect(mocks.retryWithBackoff.mock.calls.some((call) => call[1] === 'CreateCloudInstance')).toBe(false)
  })

  it('keeps an uncertain placeholder and never resubmits when create has an ambiguous failure', async () => {
    mocks.createCloudInstance.mockRejectedValue(new Error('vultr api error (500): boom'))
    const harness = createHarness()

    await expect(
      harness.api.createInstance({ label: 'New LAX', region: 'lax', plan: 'vc2-1c-1gb' }),
    ).rejects.toThrow('vultr api error (500): boom')

    expect(harness.instances.value).toContainEqual(expect.objectContaining({
      instanceId: expect.stringMatching(/^deploying-/),
      deploymentState: 'uncertain',
    }))
    expect(mocks.createCloudInstance).toHaveBeenCalledTimes(1)
    expect(mocks.listCloudInstances).toHaveBeenCalledTimes(1)
    expect(harness.creatingInstance.value).toBe(false)
    harness.api.clearAllTimers()
  })

  it('does not mistake an older same-label server for the result of an ambiguous create', async () => {
    mocks.createCloudInstance.mockRejectedValue(new Error('response lost'))
    mocks.listCloudInstances.mockResolvedValue([
      readyNode({
        instanceId: 'older-node',
        label: 'Duplicate',
        region: 'lax',
        plan: 'vc2-1c-1gb',
      }),
    ])
    const harness = createHarness()

    await expect(
      harness.api.createInstance({ label: 'Duplicate', region: 'lax', plan: 'vc2-1c-1gb' }),
    ).rejects.toThrow('response lost')

    expect(harness.instances.value).toEqual(expect.arrayContaining([
      expect.objectContaining({ instanceId: 'older-node' }),
      expect.objectContaining({
        instanceId: expect.stringMatching(/^deploying-/),
        deploymentState: 'uncertain',
        deploymentOperationId: expect.any(String),
      }),
    ]))
    harness.api.clearAllTimers()
  })

  it('assigns new stable per-item operation ids for each intentional batch click', async () => {
    mocks.createMultipleCloudInstances.mockImplementation(async (configs) =>
      configs.map((config: Record<string, string>, index: number) => ({
        id: `batch-node-${index}`,
        operationId: config.operationId,
        state: 'succeeded',
        success: true,
      })),
    )
    mocks.getCloudOperationStatus.mockImplementation(async (operationId: string) => ({
      state: 'succeeded',
      instance: readyNode({
        instanceId: `resolved-${operationId}`,
        label: operationId.endsWith('-0') ? 'A' : 'B',
      }),
    }))
    mocks.listCloudInstances.mockResolvedValue([])
    const harness = createHarness()
    const configs = [
      { label: 'A', region: 'lax', plan: 'vc2' },
      { label: 'B', region: 'nrt', plan: 'vc2' },
    ]

    await harness.api.createMultipleInstances(configs)
    await harness.api.createMultipleInstances(configs)

    const first = mocks.createMultipleCloudInstances.mock.calls[0][0]
    const second = mocks.createMultipleCloudInstances.mock.calls[1][0]
    expect(first[0].operationId).toBeTruthy()
    expect(first[0].operationId).not.toBe(first[1].operationId)
    expect(second[0].operationId).not.toBe(first[0].operationId)
    harness.api.clearAllTimers()
  })

  it('keeps exact batch placeholders and blocks a duplicate click while cloud outcome is uncertain', async () => {
    mocks.createMultipleCloudInstances.mockImplementation(async (configs) => configs.map(
      (config: Record<string, string>) => ({
        id: '',
        operationId: config.operationId,
        state: 'reconciling',
        success: false,
        error: 'provider response lost',
      }),
    ))
    mocks.getCloudOperationStatus.mockResolvedValue({ state: 'reconciling' })
    const harness = createHarness()
    const configs = [
      { label: 'Duplicate', region: 'lax', plan: 'vc2' },
      { label: 'Duplicate', region: 'lax', plan: 'vc2' },
    ]

    const results = await harness.api.createMultipleInstances(configs)

    expect(results).toHaveLength(2)
    expect(harness.instances.value).toHaveLength(2)
    expect(harness.instances.value[0].deploymentOperationId).not.toBe(
      harness.instances.value[1].deploymentOperationId,
    )
    expect(harness.instances.value).toEqual(expect.arrayContaining([
      expect.objectContaining({ deploymentState: 'uncertain', statusText: 'deploying' }),
    ]))

    await expect(harness.api.createMultipleInstances(configs)).rejects.toThrow(
      '原始云端请求仍在核对',
    )
    expect(mocks.createMultipleCloudInstances).toHaveBeenCalledTimes(1)
    harness.api.clearAllTimers()
  })

  it('restores durable pending placeholders after restart and blocks a duplicate billed request', async () => {
    mocks.listPendingCloudOperations.mockResolvedValue([{
      operationId: 'restarted-operation',
      provider: 'vultr',
      state: 'reconciling',
      label: 'Recovered LAX',
      region: 'lax',
      plan: 'vc2',
      createdAt: '2023-11-14T22:13:20Z',
      updatedAt: '2023-11-14T22:14:20Z',
    }])
    mocks.getCloudOperationStatus.mockResolvedValue({ state: 'reconciling' })
    mocks.listCloudInstances.mockResolvedValue([])
    const harness = createHarness()

    await harness.api.refreshInstances(true, true)

    expect(harness.instances.value).toContainEqual(expect.objectContaining({
      instanceId: 'deploying-restarted-operation',
      provider: 'vultr',
      label: 'Recovered LAX',
      region: 'lax',
      plan: 'vc2',
      deploymentOperationId: 'restarted-operation',
      deploymentState: 'uncertain',
    }))
    expect(mocks.getCloudOperationStatus).toHaveBeenCalledWith('restarted-operation')

    await expect(harness.api.createMultipleInstances([{
      label: 'Recovered LAX', region: 'lax', plan: 'vc2',
    }])).rejects.toThrow('原始云端请求仍在核对')
    await expect(harness.api.createInstance({
      label: 'Recovered LAX', region: 'lax', plan: 'vc2',
    })).rejects.toThrow('原始云端请求仍在核对')
    expect(mocks.createMultipleCloudInstances).not.toHaveBeenCalled()
    expect(mocks.createCloudInstance).not.toHaveBeenCalled()
    harness.api.clearAllTimers()
  })

  it('keeps the provider captured by a single create when the active provider changes', async () => {
    let resolveCreate: (value: unknown) => void = () => {}
    mocks.createCloudInstance.mockImplementation(
      () => new Promise((resolve) => { resolveCreate = resolve }),
    )
    const harness = createHarness()
    const pending = harness.api.createInstance({ label: 'Pinned', region: 'nrt', plan: 'small' })

    harness.currentProvider.value = 'digitalocean'
    resolveCreate({
      instanceId: 'pinned-node',
      label: 'Pinned',
      region: 'nrt',
      plan: 'small',
      ipv4: '203.0.113.20',
      ssPort: 8388,
      ssPassword: 'secret',
    })
    const node = await pending

    expect(node.provider).toBe('vultr')
    expect(harness.instances.value).toContainEqual(expect.objectContaining({
      instanceId: 'pinned-node',
      provider: 'vultr',
    }))
    expect(harness.ensureRegionAvailability).not.toHaveBeenCalled()
    harness.api.clearAllTimers()
  })

  it('uses a recovered placeholder provider instead of the newly active provider', async () => {
    mocks.listPendingCloudOperations.mockResolvedValue([{
      operationId: 'non-active-recovery',
      provider: 'vultr',
      state: 'reconciling',
      label: 'Recovered NRT',
      region: 'nrt',
      plan: 'small',
      createdAt: '2023-11-14T22:13:20Z',
      updatedAt: '2023-11-14T22:14:20Z',
    }])
    mocks.getCloudOperationStatus.mockResolvedValue({
      state: 'succeeded',
      instance: {
        instanceId: 'recovered-vultr-node',
        label: 'Recovered NRT',
        region: 'nrt',
        plan: 'small',
        ipv4: '203.0.113.21',
      },
    })
    const harness = createHarness()
    harness.currentProvider.value = 'digitalocean'

    await harness.api.restorePendingCreateOperations()
    await vi.waitFor(() => expect(harness.instances.value).toContainEqual(expect.objectContaining({
      instanceId: 'recovered-vultr-node',
      provider: 'vultr',
    })))

    expect(harness.ensureRegionAvailability).not.toHaveBeenCalled()
    harness.api.clearAllTimers()
  })

  it('removes and notifies for a definitively failed recovered placeholder', async () => {
    mocks.listPendingCloudOperations.mockResolvedValue([{
      operationId: 'failed-after-restart',
      provider: 'digitalocean',
      state: 'reconciling',
      label: 'Failed FRA',
      region: 'fra1',
      plan: 's-1vcpu-1gb',
      createdAt: '2023-11-14T22:13:20Z',
      updatedAt: '2023-11-14T22:14:20Z',
    }])
    mocks.getCloudOperationStatus.mockResolvedValue({
      state: 'failed',
      error: 'quota exceeded',
    })
    const harness = createHarness()

    await harness.api.restorePendingCreateOperations()
    await vi.waitFor(() => expect(harness.instances.value).toEqual([]))

    expect(mocks.notifications.deploymentFailed).toHaveBeenCalledWith(
      'Failed FRA',
      'quota exceeded',
    )
    expect(mocks.saveToOfflineCache).toHaveBeenCalledWith('nodes', [])
    expect(harness.instances.value.some((node) => node.instanceId.startsWith('deploying-'))).toBe(false)
    harness.api.clearAllTimers()
  })

  it('does not keep a fake managed row for an immediate terminal batch failure', async () => {
    mocks.createMultipleCloudInstances.mockImplementation(async (configs) => configs.map(
      (config: Record<string, string>) => ({
        id: '',
        operationId: config.operationId,
        state: 'failed',
        success: false,
        error: 'payment required',
      }),
    ))
    const harness = createHarness()

    const results = await harness.api.createMultipleInstances([{
      label: 'No Credit', region: 'nrt', plan: 'vc2',
    }])

    expect(results[0].state).toBe('failed')
    expect(harness.instances.value).toEqual([])
    expect(mocks.notifications.deploymentFailed).toHaveBeenCalledWith(
      'No Credit',
      'payment required',
    )
  })

  it('fails closed for destructive actions on a node owned by another provider', async () => {
    const foreignNode = readyNode({ provider: 'digitalocean' })
    const harness = createHarness({ instances: [foreignNode] })

    await expect(harness.api.destroyInstance(foreignNode.instanceId)).rejects.toThrow(
      'Switch to digitalocean before deleting it',
    )
    await expect(harness.api.rotateIP(foreignNode.instanceId)).rejects.toThrow(
      'Switch to digitalocean before rotating its IP',
    )
    await expect(harness.api.redeployInstance(foreignNode.instanceId)).rejects.toThrow(
      'Switch to digitalocean before repairing or redeploying it',
    )

    expect(mocks.destroyCloudInstance).not.toHaveBeenCalled()
    expect(mocks.createCloudInstance).not.toHaveBeenCalled()
    expect(mocks.repairCloudInstance).not.toHaveBeenCalled()
    expect(harness.instances.value).toEqual([foreignNode])
  })

  it('fails closed for destructive actions when provider ownership is missing or the node is unknown', async () => {
    const unattributedNode = readyNode({ provider: undefined })
    const harness = createHarness({ instances: [unattributedNode] })

    await expect(harness.api.destroyInstance(unattributedNode.instanceId)).rejects.toThrow(
      'belongs to an unknown provider',
    )
    await expect(harness.api.rotateIP(unattributedNode.instanceId)).rejects.toThrow(
      'belongs to an unknown provider',
    )
    await expect(harness.api.redeployInstance(unattributedNode.instanceId)).rejects.toThrow(
      'belongs to an unknown provider',
    )
    await expect(harness.api.destroyInstance('missing-node')).rejects.toThrow(
      'Node not found for deletion',
    )

    expect(mocks.destroyCloudInstance).not.toHaveBeenCalled()
    expect(mocks.createCloudInstance).not.toHaveBeenCalled()
    expect(mocks.repairCloudInstance).not.toHaveBeenCalled()
  })

  it('detaches an in-flight create and keeps reconciling its stable operation id', async () => {
    let rejectCreate: (reason: Error) => void = () => {}
    mocks.createCloudInstance.mockImplementation(
      () => new Promise((_, reject) => { rejectCreate = reject }),
    )
    const harness = createHarness()
    const pending = harness.api.createInstance({ label: 'Cancelable', region: 'lax', plan: 'vc2' })
    const operationId = harness.instances.value[0].deploymentOperationId || ''
    mocks.listCloudInstances.mockResolvedValue([])

    expect(operationId).not.toBe('')
    await harness.api.cancelCreate(operationId)

    expect(mocks.cancelCloudOperation).toHaveBeenCalledWith(operationId)
    expect(harness.instances.value).toContainEqual(expect.objectContaining({
      deploymentOperationId: operationId,
      deploymentState: 'uncertain',
    }))
    expect(mocks.getCloudOperationStatus).toHaveBeenCalledWith(operationId)
    expect(mocks.listCloudInstances).not.toHaveBeenCalled()

    rejectCreate(new Error('operation canceled'))
    await expect(pending).resolves.toMatchObject({ deploymentState: 'uncertain' })
    expect(mocks.createCloudInstance).toHaveBeenCalledTimes(1)
    expect(mocks.listCloudInstances).not.toHaveBeenCalled()
    harness.api.clearAllTimers()
  })

  it('replaces a detached placeholder with the original completed operation result', async () => {
    let rejectCreate: (reason: Error) => void = () => {}
    mocks.createCloudInstance.mockImplementation(
      () => new Promise((_, reject) => { rejectCreate = reject }),
    )
    mocks.getCloudOperationStatus.mockResolvedValue({
      state: 'succeeded',
      instance: readyNode({ instanceId: 'detached-node', label: 'Detached', ipv4: '1.2.3.4' }),
    })
    const harness = createHarness()
    const pending = harness.api.createInstance({ label: 'Detached', region: 'nrt', plan: 'vc2-1c-1gb' })
    const operationId = harness.instances.value[0].deploymentOperationId || ''

    await harness.api.cancelCreate(operationId)
    await vi.waitFor(() => {
      expect(harness.instances.value).toContainEqual(expect.objectContaining({
        instanceId: 'detached-node',
        deploymentOperationId: undefined,
      }))
    })
    await vi.waitFor(() => {
      expect(harness.ensureSubscriptionForNode).toHaveBeenCalledWith(
        expect.objectContaining({ instanceId: 'detached-node' }),
      )
    })

    rejectCreate(new Error('stopped waiting'))
    await expect(pending).resolves.toMatchObject({
      instanceId: 'detached-node',
      deploymentOperationId: undefined,
    })
    expect(mocks.createCloudInstance).toHaveBeenCalledTimes(1)
    harness.api.clearAllTimers()
  })

  it('keeps polling the exact operation when an immediate refresh cannot see a detached server yet', async () => {
    let rejectCreate: (reason: Error) => void = () => {}
    mocks.createCloudInstance.mockImplementation(
      () => new Promise((_, reject) => { rejectCreate = reject }),
    )
    mocks.getCloudOperationStatus
      .mockResolvedValueOnce({ state: 'running' })
      .mockResolvedValueOnce({
        state: 'succeeded',
        instance: readyNode({ instanceId: 'eventual-node', label: 'Eventual' }),
      })
    mocks.listCloudInstances.mockResolvedValue([])
    const harness = createHarness()
    const pending = harness.api.createInstance({ label: 'Eventual', region: 'nrt', plan: 'vc2' })
    const operationId = harness.instances.value[0].deploymentOperationId || ''

    await harness.api.cancelCreate(operationId)
    await harness.api.refreshInstances(true, true)
    expect(harness.instances.value).toContainEqual(expect.objectContaining({
      deploymentOperationId: operationId,
      deploymentState: 'uncertain',
    }))

    rejectCreate(new Error('stopped waiting'))
    await pending
    await vi.waitFor(() => {
      expect(harness.instances.value).toContainEqual(expect.objectContaining({
        instanceId: 'eventual-node',
        deploymentOperationId: undefined,
      }))
    })
    expect(mocks.createCloudInstance).toHaveBeenCalledTimes(1)
    harness.api.clearAllTimers()
  })

  it('clears a previous deployment warning when a forced refresh returns an empty warning', async () => {
    mocks.listCloudInstances.mockResolvedValue([
      readyNode({ lastDeployWarning: '' }),
    ])
    const harness = createHarness({
      instances: [readyNode({ lastDeployWarning: 'service readiness failed: timeout' })],
    })

    await harness.api.refreshInstances(false, true)

    expect(harness.instances.value[0].lastDeployWarning).toBe('')
  })
})
