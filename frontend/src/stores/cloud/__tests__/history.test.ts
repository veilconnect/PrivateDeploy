import { beforeEach, describe, expect, it, vi } from 'vitest'
import { ref, shallowRef } from 'vue'

const bridgeMocks = vi.hoisted(() => ({
  readFile: vi.fn(),
  writeFile: vi.fn(),
}))

vi.mock('@/bridge', () => ({
  ReadFile: bridgeMocks.readFile,
  WriteFile: bridgeMocks.writeFile,
}))

import { createCloudHistory } from '../history'

describe('cloud history', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.clearAllMocks()
  })

  it('prunes expired samples on load and persists new real samples', async () => {
    const now = new Date('2026-03-25T00:00:00Z').getTime()
    vi.setSystemTime(now)

    bridgeMocks.readFile.mockResolvedValue(JSON.stringify({
      'node-1': {
        connectivity: [
          { timestamp: now - 8 * 24 * 60 * 60 * 1000, status: 'blocked' },
          { timestamp: now - 60 * 1000, status: 'reachable' },
        ],
        speed: [
          { timestamp: now - 8 * 24 * 60 * 60 * 1000, speedMbps: 1.2, status: 'ok' },
          { timestamp: now - 30 * 1000, speedMbps: 88.8, status: 'ok' },
        ],
      },
    }))
    bridgeMocks.writeFile.mockResolvedValue(undefined)

    const nodeHistory = shallowRef({})
    const nodeHistoryLoaded = ref(false)
    const history = createCloudHistory({
      nodeHistory,
      nodeHistoryLoaded,
    })

    await history.loadNodeHistory()

    expect(nodeHistory.value['node-1'].connectivity).toHaveLength(1)
    expect(nodeHistory.value['node-1'].speed).toHaveLength(1)

    await history.recordConnectivitySample('node-1', 'blocked', {
      ip: '203.0.113.10',
      icmpReachable: false,
      portsOpen: { '443': false },
      status: 'blocked',
    })
    await history.recordSpeedSample('node-1', {
      speedMbps: 66.6,
      status: 'ok',
    })

    await vi.runAllTimersAsync()
    await Promise.resolve()

    expect(bridgeMocks.writeFile).toHaveBeenCalled()
    const [, writtenPayload] = bridgeMocks.writeFile.mock.calls.at(-1)!
    const persisted = JSON.parse(writtenPayload)

    expect(persisted['node-1'].connectivity).toHaveLength(2)
    expect(persisted['node-1'].speed).toHaveLength(2)
    expect(persisted['node-1'].speed[1]).toMatchObject({
      speedMbps: 66.6,
      status: 'ok',
    })
  })

  it('can clear history for a single node and persist removal', async () => {
    bridgeMocks.readFile.mockResolvedValue(JSON.stringify({
      'node-1': {
        connectivity: [{ timestamp: Date.now(), status: 'reachable' }],
        speed: [{ timestamp: Date.now(), speedMbps: 12.3, status: 'ok' }],
      },
      'node-2': {
        connectivity: [{ timestamp: Date.now(), status: 'blocked' }],
        speed: [],
      },
    }))
    bridgeMocks.writeFile.mockResolvedValue(undefined)

    const nodeHistory = shallowRef({})
    const nodeHistoryLoaded = ref(false)
    const history = createCloudHistory({
      nodeHistory,
      nodeHistoryLoaded,
    })

    await history.clearNodeHistory('node-1')

    expect(nodeHistory.value['node-1']).toBeUndefined()
    expect(nodeHistory.value['node-2']).toBeTruthy()

    const [, writtenPayload] = bridgeMocks.writeFile.mock.calls.at(-1)!
    const persisted = JSON.parse(writtenPayload)
    expect(persisted['node-1']).toBeUndefined()
    expect(persisted['node-2']).toBeTruthy()
  })

  it('preserves speed error reasons when loading and recording failures', async () => {
    const now = new Date('2026-03-25T00:00:00Z').getTime()
    vi.setSystemTime(now)

    bridgeMocks.readFile.mockResolvedValue(JSON.stringify({
      'node-1': {
        connectivity: [],
        speed: [
          { timestamp: now - 30 * 1000, status: 'error', error: 'sing-box binary not found' },
        ],
      },
    }))
    bridgeMocks.writeFile.mockResolvedValue(undefined)

    const nodeHistory = shallowRef({})
    const nodeHistoryLoaded = ref(false)
    const history = createCloudHistory({
      nodeHistory,
      nodeHistoryLoaded,
    })

    await history.loadNodeHistory()
    expect(nodeHistory.value['node-1'].speed[0]).toMatchObject({
      status: 'error',
      error: 'sing-box binary not found',
    })

    await history.recordSpeedSample('node-1', {
      status: 'timeout',
      error: 'context deadline exceeded',
    })

    await vi.runAllTimersAsync()
    await Promise.resolve()

    const [, writtenPayload] = bridgeMocks.writeFile.mock.calls.at(-1)!
    const persisted = JSON.parse(writtenPayload)
    expect(persisted['node-1'].speed).toHaveLength(2)
    expect(persisted['node-1'].speed[1]).toMatchObject({
      status: 'timeout',
      error: 'context deadline exceeded',
    })
  })

  it('migrates history from a replaced instance id into the live node id', async () => {
    const now = new Date('2026-04-03T00:00:00Z').getTime()
    vi.setSystemTime(now)

    bridgeMocks.readFile.mockResolvedValue(JSON.stringify({
      'old-node': {
        connectivity: [{ timestamp: now - 60_000, status: 'reachable' }],
        speed: [{ timestamp: now - 30_000, speedMbps: 42.5, status: 'ok' }],
      },
      'new-node': {
        connectivity: [{ timestamp: now - 10_000, status: 'blocked' }],
        speed: [],
      },
    }))
    bridgeMocks.writeFile.mockResolvedValue(undefined)

    const nodeHistory = shallowRef({})
    const nodeHistoryLoaded = ref(false)
    const history = createCloudHistory({
      nodeHistory,
      nodeHistoryLoaded,
    })

    const migrated = await history.migrateNodeHistory('old-node', 'new-node')

    expect(migrated).toBe(true)
    expect(nodeHistory.value['old-node']).toBeUndefined()
    expect(nodeHistory.value['new-node'].connectivity).toHaveLength(2)
    expect(nodeHistory.value['new-node'].speed).toHaveLength(1)

    const [, writtenPayload] = bridgeMocks.writeFile.mock.calls.at(-1)!
    const persisted = JSON.parse(writtenPayload)
    expect(persisted['old-node']).toBeUndefined()
    expect(persisted['new-node'].connectivity).toHaveLength(2)
  })
})
