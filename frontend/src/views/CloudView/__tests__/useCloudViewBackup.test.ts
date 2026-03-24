import { beforeEach, describe, expect, it, vi } from 'vitest'

const bridgeMocks = vi.hoisted(() => ({
  exportCloudBackup: vi.fn(),
  importCloudBackup: vi.fn(),
}))

const messageMocks = vi.hoisted(() => ({
  success: vi.fn(),
  error: vi.fn(),
}))

vi.mock('@/bridge', () => ({
  ExportCloudBackup: bridgeMocks.exportCloudBackup,
  ImportCloudBackup: bridgeMocks.importCloudBackup,
}))

vi.mock('@/utils', () => ({
  message: {
    success: messageMocks.success,
    error: messageMocks.error,
  },
}))

import { useCloudViewBackup } from '../useCloudViewBackup'

describe('useCloudViewBackup', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('restores backup into the existing config object before saving', async () => {
    const config = {
      provider: 'vultr',
      apiKey: 'old-key',
      defaultRegion: 'nrt',
      defaultPlan: 'vc2-1c-1gb',
      extra: {},
    }
    const saveConfig = vi.fn().mockResolvedValue(undefined)
    const fetchMeta = vi.fn().mockResolvedValue(undefined)
    const handleError = vi.fn()

    bridgeMocks.importCloudBackup.mockResolvedValue(JSON.stringify({
      version: '1.0.0',
      timestamp: Date.now(),
      cloudConfig: {
        provider: 'vultr',
        apiKey: 'new-key',
        defaultRegion: 'fra',
        defaultPlan: 'vc2-1c-1gb',
        extra: { note: 'restored' },
      },
    }))

    const { handleRestoreConfig } = useCloudViewBackup({
      cloudStore: {
        config,
        saveConfig,
      },
      fetchMeta,
      handleError,
      translate: (key) => key,
    })

    await handleRestoreConfig()

    expect(config.defaultRegion).toBe('fra')
    expect(config.apiKey).toBe('new-key')
    expect(config.extra).toEqual({ note: 'restored' })
    expect(saveConfig).toHaveBeenCalledTimes(1)
    expect(fetchMeta).toHaveBeenCalledTimes(1)
    expect(handleError).not.toHaveBeenCalled()
    expect(messageMocks.success).toHaveBeenCalledWith('cloud.backup.imported')
  })
})
