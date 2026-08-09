import { describe, expect, it, vi } from 'vitest'

import { shouldRedirectToWizard } from '../startupGuard'

import type { StartupCloudState } from '../startupGuard'
import type { ManagedCloudNode } from '@/stores/cloud/types'

const cloudState = (overrides: Partial<StartupCloudState> = {}): StartupCloudState => ({
  currentProvider: 'vultr',
  config: { apiKey: '', extra: {} },
  instances: [],
  getCurrentProvider: vi.fn(async () => undefined),
  loadConfig: vi.fn(async () => undefined),
  loadManualNodes: vi.fn(async () => []),
  ...overrides,
})

describe('initial cloud route guard', () => {
  it('never starts or awaits the remote inventory refresh', async () => {
    const refreshInstances = vi.fn(() => new Promise<void>(() => {}))
    const cloud = {
      ...cloudState(),
      // Model the old 3 x 45 second ListCloudInstances path. It deliberately
      // never settles; the local-only guard must not call it at all.
      refreshInstances,
    }

    const result = await Promise.race([
      shouldRedirectToWizard(cloud, () => null),
      new Promise<never>((_, reject) => {
        window.setTimeout(() => reject(new Error('startup guard blocked on remote API')), 50)
      }),
    ])

    expect(result).toBe(true)
    expect(refreshInstances).not.toHaveBeenCalled()
    expect(cloud.loadConfig).toHaveBeenCalledWith({ startAutoRefresh: false })
  })

  it('syncs the persisted backend provider before loading its config', async () => {
    const calls: string[] = []
    const cloud = cloudState({
      getCurrentProvider: vi.fn(async () => {
        calls.push('provider')
      }),
      loadConfig: vi.fn(async () => {
        calls.push('config')
      }),
      loadManualNodes: vi.fn(async () => {
        calls.push('manual')
        return []
      }),
    })

    await shouldRedirectToWizard(cloud, () => null)

    expect(calls).toEqual(['provider', 'config', 'manual'])
  })

  it('keeps the workspace when local config loading is temporarily unavailable', async () => {
    const cloud = cloudState({
      loadConfig: vi.fn(async () => {
        throw new Error('secret store is temporarily locked')
      }),
    })

    await expect(shouldRedirectToWizard(cloud, () => null)).resolves.toBe(false)
  })

  it('uses existing in-memory, manual, or offline nodes without a provider API call', async () => {
    const cachedNode: ManagedCloudNode = {
      instanceId: 'cached-node',
      label: 'Cached',
      provider: 'vultr',
    }
    const cloud = cloudState()

    await expect(shouldRedirectToWizard(cloud, () => [cachedNode])).resolves.toBe(false)

    const manualNode: ManagedCloudNode = {
      instanceId: 'manual-node',
      label: 'Manual',
      provider: 'manual',
    }
    const manualCloud = cloudState()
    manualCloud.loadManualNodes = vi.fn(async () => {
      manualCloud.instances.push(manualNode)
      return [manualNode]
    })
    await expect(shouldRedirectToWizard(manualCloud, () => null)).resolves.toBe(false)
  })

  it('does not require an API key for the SSH provider', async () => {
    const cloud = cloudState({ currentProvider: 'ssh' })

    await expect(shouldRedirectToWizard(cloud, () => null)).resolves.toBe(false)
  })

  it('redirects only after local state conclusively shows a first run', async () => {
    const cloud = cloudState()

    await expect(shouldRedirectToWizard(cloud, () => null)).resolves.toBe(true)

    cloud.config.apiKey = 'saved-locally'
    await expect(shouldRedirectToWizard(cloud, () => null)).resolves.toBe(false)
  })
})
