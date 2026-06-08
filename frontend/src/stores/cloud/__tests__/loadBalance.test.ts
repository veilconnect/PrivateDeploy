import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  getAvailablePort: vi.fn(),
  startLoadBalancer: vi.fn(),
  stopLoadBalancer: vi.fn(),
  registerConfigWriteHook: vi.fn(),
  unregisterConfigWriteHook: vi.fn(),
  injectLoadBalanceConfig: vi.fn(),
}))

vi.mock('@/bridge', () => ({
  GetAvailablePort: mocks.getAvailablePort,
  StartLoadBalancer: mocks.startLoadBalancer,
  StopLoadBalancer: mocks.stopLoadBalancer,
}))

vi.mock('../../kernelApi', () => ({
  registerConfigWriteHook: mocks.registerConfigWriteHook,
  unregisterConfigWriteHook: mocks.unregisterConfigWriteHook,
}))

vi.mock('../smartRouting', () => ({
  injectLoadBalanceConfig: mocks.injectLoadBalanceConfig,
}))

import { createCloudLoadBalance } from '../loadBalance'

describe('createCloudLoadBalance', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.clearAllMocks()
    vi.spyOn(console, 'info').mockImplementation(() => {})
    vi.spyOn(console, 'error').mockImplementation(() => {})
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it('registers the config hook, restarts a running kernel, and starts the load balancer', async () => {
    let configHook: ((config: Record<string, any>) => Promise<void>) | undefined
    mocks.registerConfigWriteHook.mockImplementation((hook) => {
      configHook = hook
    })
    mocks.getAvailablePort.mockResolvedValueOnce(10_000).mockResolvedValueOnce(11_000)
    mocks.injectLoadBalanceConfig.mockReturnValue([10_000, 10_001])
    mocks.startLoadBalancer.mockResolvedValue({ flag: true, data: '' })

    const kernelApi = {
      running: true,
      restartCore: vi.fn(async () => {
        await configHook?.({ outbounds: [{ tag: 'Proxy' }], inbounds: [] })
      }),
      startCore: vi.fn(),
    }
    const loadBalance = createCloudLoadBalance({ kernelApi })

    const task = loadBalance.startLoadBalance()
    await vi.advanceTimersByTimeAsync(3_000)
    await task

    expect(mocks.registerConfigWriteHook).toHaveBeenCalledWith(configHook)
    expect(kernelApi.restartCore).toHaveBeenCalledTimes(1)
    expect(kernelApi.startCore).not.toHaveBeenCalled()
    expect(mocks.injectLoadBalanceConfig).toHaveBeenCalledWith(
      { outbounds: [{ tag: 'Proxy' }], inbounds: [] },
      10_000,
    )
    expect(mocks.startLoadBalancer).toHaveBeenCalledWith(11_000, JSON.stringify([10_000, 10_001]))
    expect(loadBalance.loadBalanceEnabled.value).toBe(true)
    expect(loadBalance.loadBalanceListenPort.value).toBe(11_000)
  })

  it('starts a stopped kernel and rolls back when fewer than two ports are injected', async () => {
    let configHook: ((config: Record<string, any>) => Promise<void>) | undefined
    mocks.registerConfigWriteHook.mockImplementation((hook) => {
      configHook = hook
    })
    mocks.getAvailablePort.mockResolvedValue(10_000)
    mocks.injectLoadBalanceConfig.mockReturnValue([10_000])

    const kernelApi = {
      running: false,
      restartCore: vi.fn(),
      startCore: vi.fn(async () => {
        await configHook?.({ outbounds: [{ tag: 'Only node' }], inbounds: [] })
      }),
    }
    const loadBalance = createCloudLoadBalance({ kernelApi })

    const task = loadBalance.startLoadBalance()
    await vi.advanceTimersByTimeAsync(3_000)
    await task

    expect(kernelApi.startCore).toHaveBeenCalledTimes(1)
    expect(mocks.startLoadBalancer).not.toHaveBeenCalled()
    expect(mocks.unregisterConfigWriteHook).toHaveBeenCalledWith(configHook)
    expect(loadBalance.loadBalanceEnabled.value).toBe(false)
  })

  it('clears listener state when stopping load balancing', async () => {
    const loadBalance = createCloudLoadBalance({
      kernelApi: {
        running: false,
        restartCore: vi.fn(),
        startCore: vi.fn(),
      },
    })

    await loadBalance.stopLoadBalance()

    expect(mocks.unregisterConfigWriteHook).toHaveBeenCalled()
    expect(mocks.stopLoadBalancer).toHaveBeenCalledTimes(1)
    expect(loadBalance.loadBalanceEnabled.value).toBe(false)
    expect(loadBalance.loadBalanceListenPort.value).toBe(0)
  })
})
