import { beforeEach, describe, expect, it, vi } from 'vitest'
import { ref, shallowRef } from 'vue'

const mocks = vi.hoisted(() => ({
  readFile: vi.fn(),
  writeFile: vi.fn(),
  sampleID: vi.fn(() => 'seed'),
}))

vi.mock('@/bridge', () => ({
  ReadFile: mocks.readFile,
  WriteFile: mocks.writeFile,
}))

vi.mock('@/utils', () => ({
  debounce: (fn: (...args: any[]) => any) => fn,
  ignoredError: async (fn: (...args: any[]) => any, ...args: any[]) => {
    try {
      return await fn(...args)
    } catch {
      return undefined
    }
  },
  sampleID: mocks.sampleID,
}))

import { manualNodesPath } from '../constants'
import { createManualImport } from '../manualImport'
import { ManualNodeError } from '../types'

import type { ManagedCloudNode, ManualNodeInput } from '../types'

const createHarness = (options: {
  stored?: ManagedCloudNode[]
  instances?: ManagedCloudNode[]
} = {}) => {
  const manualNodes = shallowRef<ManagedCloudNode[]>([])
  const manualNodesLoaded = ref(false)
  const instances = shallowRef<ManagedCloudNode[]>(options.instances ?? [])
  const instancesUpdatedAt = ref<number | null>(null)
  const markNodeStatus = vi.fn()
  const ensureSubscriptionForNode = vi.fn().mockResolvedValue(undefined)

  mocks.readFile.mockResolvedValue(
    options.stored === undefined ? '' : JSON.stringify(options.stored),
  )

  const api = createManualImport({
    manualNodes,
    manualNodesLoaded,
    instances,
    instancesUpdatedAt,
    markNodeStatus,
    ensureSubscriptionForNode,
  })

  return {
    api,
    manualNodes,
    manualNodesLoaded,
    instances,
    instancesUpdatedAt,
    markNodeStatus,
    ensureSubscriptionForNode,
  }
}

describe('createManualImport', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.spyOn(Date.prototype, 'toISOString').mockReturnValue('2026-05-13T00:00:00.000Z')
  })

  it('loads stored manual nodes, normalizes defaults, and syncs them into instances', async () => {
    const stored = [{
      instanceId: 'cloud-manual-1',
      label: 'Manual One',
      provider: '' as any,
      ipv4: '203.0.113.10',
      ssPort: 8388,
      ssPassword: 'secret',
    }] as ManagedCloudNode[]
    const remote = {
      instanceId: 'cloud-remote-1',
      label: 'Remote One',
      provider: 'vultr',
      ipv4: '198.51.100.20',
    } as ManagedCloudNode
    const harness = createHarness({ stored, instances: [remote] })

    await expect(harness.api.loadManualNodes()).resolves.toEqual([
      expect.objectContaining({
        instanceId: 'cloud-manual-1',
        provider: 'manual',
        status: 'active',
        statusText: 'connected',
        createdAt: '2026-05-13T00:00:00.000Z',
      }),
    ])

    expect(mocks.readFile).toHaveBeenCalledWith(manualNodesPath)
    expect(harness.manualNodesLoaded.value).toBe(true)
    expect(harness.instances.value).toEqual([
      remote,
      expect.objectContaining({ instanceId: 'cloud-manual-1', provider: 'manual' }),
    ])
    expect(harness.instancesUpdatedAt.value).toBeTypeOf('number')
  })

  it('adds valid nodes, skips duplicate imports, and creates subscriptions for additions', async () => {
    const remote = {
      instanceId: 'cloud-remote-1',
      label: 'Remote One',
      provider: 'vultr',
      ipv4: '198.51.100.20',
    } as ManagedCloudNode
    const harness = createHarness({ instances: [remote] })

    const inputs: ManualNodeInput[] = [
      {
        label: '  Tokyo Manual  ',
        ipv4: ' 203.0.113.30 ',
        ssPort: 8388,
        ssPassword: ' ss-secret ',
      },
      {
        label: 'Duplicate Remote',
        ipv4: '198.51.100.20',
        ssPort: 8389,
        ssPassword: 'another-secret',
      },
    ]

    const result = await harness.api.addManualNodes(inputs)

    expect(result.added).toEqual([
      expect.objectContaining({
        instanceId: 'cloud-manual-seed',
        label: 'Tokyo Manual',
        provider: 'manual',
        ipv4: '203.0.113.30',
        ssPort: 8388,
        ssPassword: 'ss-secret',
      }),
    ])
    expect(result.skipped).toEqual([
      {
        identifier: '198.51.100.20',
        reason: 'ipv4',
        existingLabel: 'Remote One',
        existingProvider: 'vultr',
      },
    ])
    expect(mocks.writeFile).toHaveBeenCalledWith(
      manualNodesPath,
      expect.stringContaining('"label": "Tokyo Manual"'),
    )
    expect(harness.ensureSubscriptionForNode).toHaveBeenCalledWith(result.added[0])
    expect(harness.markNodeStatus).toHaveBeenCalledWith('cloud-manual-seed', 'connected')
  })

  it('throws a duplicate error when every imported node conflicts', async () => {
    const harness = createHarness({
      stored: [{
        instanceId: 'cloud-manual-existing',
        label: 'Existing',
        provider: 'manual',
        ipv4: '203.0.113.40',
        ssPort: 8388,
        ssPassword: 'secret',
      } as ManagedCloudNode],
    })

    await expect(
      harness.api.addManualNodes([{
        label: 'Existing',
        ipv4: '203.0.113.50',
        ssPort: 8389,
        ssPassword: 'secret',
      }]),
    ).rejects.toMatchObject({
      code: 'duplicate',
      meta: {
        skipped: [
          expect.objectContaining({
            identifier: 'Existing',
            reason: 'label',
          }),
        ],
      },
    } satisfies Partial<ManualNodeError>)
    expect(mocks.writeFile).not.toHaveBeenCalled()
  })

  it('updates a manual node while preserving identity and createdAt', async () => {
    const harness = createHarness({
      stored: [{
        instanceId: 'cloud-manual-existing',
        label: 'Existing',
        provider: 'manual',
        ipv4: '203.0.113.60',
        ssPort: 8388,
        ssPassword: 'old-secret',
        createdAt: '2025-01-01T00:00:00.000Z',
      } as ManagedCloudNode],
    })

    const updated = await harness.api.updateManualNode('cloud-manual-existing', {
      label: 'Updated',
      ipv4: '203.0.113.61',
      trojanPort: 443,
      trojanPassword: 'trojan-secret',
    })

    expect(updated).toMatchObject({
      instanceId: 'cloud-manual-existing',
      label: 'Updated',
      ipv4: '203.0.113.61',
      ssPort: 8388,
      ssPassword: 'old-secret',
      trojanPort: 443,
      trojanPassword: 'trojan-secret',
      createdAt: '2025-01-01T00:00:00.000Z',
    })
    expect(harness.ensureSubscriptionForNode).toHaveBeenCalledWith(updated)
    expect(harness.markNodeStatus).toHaveBeenCalledWith('cloud-manual-existing', 'connected')
    expect(mocks.writeFile).toHaveBeenCalledWith(
      manualNodesPath,
      expect.stringContaining('"label": "Updated"'),
    )
  })

  it('rejects inputs without any supported protocol credential', async () => {
    const harness = createHarness()

    await expect(
      harness.api.addManualNode({
        label: 'No Protocol',
        ipv4: '203.0.113.70',
      }),
    ).rejects.toMatchObject({ code: 'protocol-required' })
  })
})
