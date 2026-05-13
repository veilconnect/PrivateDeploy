import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  messageWarn: vi.fn(),
  onCoreStarted: vi.fn(),
  onPortsAdjusted: vi.fn(),
  pruneMissingKernelCloudSubscriptions: vi.fn(),
  reassignKernelProfilePorts: vi.fn(),
  removeFile: vi.fn(),
  runCoreProcess: vi.fn(),
  writeConfig: vi.fn(),
  log: vi.fn(),
}))

vi.mock('@/bridge', () => ({
  RemoveFile: mocks.removeFile,
}))

vi.mock('@/utils', () => ({
  message: {
    warn: mocks.messageWarn,
  },
}))

vi.mock('../kernelApiRuntime', () => ({
  pruneMissingKernelCloudSubscriptions: mocks.pruneMissingKernelCloudSubscriptions,
  reassignKernelProfilePorts: mocks.reassignKernelProfilePorts,
}))

import { runKernelStartAttempts } from '../kernelApiStartRunner'

const run = (profileToUse: any = { id: 'profile-1' }) => runKernelStartAttempts({
  isAlpha: false,
  log: mocks.log,
  onCoreStarted: mocks.onCoreStarted,
  onPortsAdjusted: mocks.onPortsAdjusted,
  profileToUse,
  runCoreProcess: mocks.runCoreProcess,
  writeConfig: mocks.writeConfig,
})

describe('kernel api start runner', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mocks.onCoreStarted.mockResolvedValue(undefined)
    mocks.pruneMissingKernelCloudSubscriptions.mockResolvedValue({ changed: false, removed: [] })
    mocks.reassignKernelProfilePorts.mockResolvedValue({ changed: false, ports: {} })
    mocks.removeFile.mockResolvedValue(undefined)
    mocks.runCoreProcess.mockResolvedValue(1234)
    mocks.writeConfig.mockResolvedValue(undefined)
  })

  it('starts the core on the first attempt and records the pid', async () => {
    await expect(run()).resolves.toEqual({
      missingCloudSubscriptionsPruned: false,
      portsAdjusted: false,
    })

    expect(mocks.writeConfig).toHaveBeenCalledTimes(1)
    expect(mocks.runCoreProcess).toHaveBeenCalledWith(false)
    expect(mocks.onCoreStarted).toHaveBeenCalledWith(1234)
    expect(mocks.log).toHaveBeenCalledWith('[KernelApi] Core started successfully on attempt 1')
  })

  it('removes a corrupt cache file and retries cache initialization failures', async () => {
    mocks.runCoreProcess
      .mockRejectedValueOnce('initialize cache-file failed')
      .mockResolvedValueOnce(2345)

    await expect(run()).resolves.toEqual({
      missingCloudSubscriptionsPruned: false,
      portsAdjusted: false,
    })

    expect(mocks.removeFile).toHaveBeenCalledWith('data/sing-box/cache.db')
    expect(mocks.messageWarn).toHaveBeenCalledWith('kernel.errors.cacheResetting')
    expect(mocks.runCoreProcess).toHaveBeenCalledTimes(2)
  })

  it('reassigns ports after bind conflicts and reports adjusted ports', async () => {
    mocks.runCoreProcess
      .mockRejectedValueOnce('bind: address already in use')
      .mockResolvedValueOnce(3456)
    mocks.reassignKernelProfilePorts.mockResolvedValueOnce({
      changed: true,
      ports: { mixed: 3900 },
    })

    await expect(run()).resolves.toEqual({
      missingCloudSubscriptionsPruned: false,
      portsAdjusted: true,
    })

    expect(mocks.reassignKernelProfilePorts).toHaveBeenCalledWith({ id: 'profile-1' })
    expect(mocks.onPortsAdjusted).toHaveBeenCalledWith({ mixed: 3900 })
    expect(mocks.messageWarn).toHaveBeenCalledWith('kernel.errors.portResetting')
  })

  it('prunes missing cloud subscription files and retries', async () => {
    const profile = { id: 'profile-1', outbounds: [] }
    mocks.runCoreProcess
      .mockRejectedValueOnce('open data/subscribes/cloud-a.json: no such file or directory')
      .mockResolvedValueOnce(4567)
    mocks.pruneMissingKernelCloudSubscriptions.mockResolvedValueOnce({
      changed: true,
      removed: ['cloud-a'],
    })

    await expect(run(profile)).resolves.toEqual({
      missingCloudSubscriptionsPruned: true,
      portsAdjusted: false,
    })

    expect(mocks.pruneMissingKernelCloudSubscriptions).toHaveBeenCalledWith(profile)
    expect(mocks.log).toHaveBeenCalledWith('[KernelApi] Removed missing cloud subscriptions: cloud-a')
  })

  it('throws immediately for unrecoverable startup errors', async () => {
    mocks.runCoreProcess.mockRejectedValue('fatal startup error')

    await expect(run()).rejects.toBe('fatal startup error')

    expect(mocks.runCoreProcess).toHaveBeenCalledTimes(1)
    expect(mocks.log).toHaveBeenCalledWith(
      '[KernelApi] startCore attempt 1/5 failed: fatal startup error',
    )
  })
})
