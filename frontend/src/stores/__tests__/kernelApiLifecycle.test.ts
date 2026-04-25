import { describe, expect, it, vi, beforeEach } from 'vitest'
import { ref } from 'vue'

const mocks = vi.hoisted(() => ({
  readFile: vi.fn(),
  processInfo: vi.fn(),
  writeFile: vi.fn(),
  removeFile: vi.fn(),
  killProcess: vi.fn(),
}))

vi.mock('@/bridge', () => ({
  KillProcess: mocks.killProcess,
  ProcessInfo: mocks.processInfo,
  ReadFile: mocks.readFile,
  RemoveFile: mocks.removeFile,
  WriteFile: mocks.writeFile,
}))

vi.mock('@/constant/kernel', () => ({
  CorePidFilePath: 'data/corepid',
}))

vi.mock('@/utils', () => ({
  message: {
    error: vi.fn(),
    warn: vi.fn(),
    info: vi.fn(),
    success: vi.fn(),
  },
}))

import { createKernelApiLifecycleManager } from '@/stores/kernelApiLifecycle'

const noop = () => Promise.resolve()
const noopUnknown = () => Promise.resolve<unknown>(undefined)

type Harness = ReturnType<typeof build>

const build = () => {
  const corePid = ref(-1)
  const running = ref(false)
  const stopping = ref(false)
  const restarting = ref(false)
  const coreStateLoading = ref(false)

  const refreshConfig = vi.fn(noop)
  const refreshProviderProxies = vi.fn(noop)
  const startCore = vi.fn(noop)
  const restoreSystemProxyAfterUnexpectedExit = vi.fn(noopUnknown)
  const updateSystemProxyStatus = vi.fn(noopUnknown)
  const setSystemProxyIfSafe = vi.fn(() => Promise.resolve(true))
  const restorePreviousSystemProxy = vi.fn(noopUnknown)
  const onBeforeCoreStopTrigger = vi.fn(noopUnknown)
  const onCoreStartedTrigger = vi.fn(noopUnknown)
  const onCoreStoppedTrigger = vi.fn(noopUnknown)
  const startCoreWebsockets = vi.fn()
  const stopCoreWebsockets = vi.fn()

  const manager = createKernelApiLifecycleManager({
    corePid,
    running,
    stopping,
    restarting,
    coreStateLoading,
    refreshConfig,
    refreshProviderProxies,
    startCore,
    getRuntimeProfile: () => undefined,
    isAutoStartKernelEnabled: () => true,
    isAutoSetSystemProxyEnabled: () => false,
    restoreSystemProxyAfterUnexpectedExit,
    updateSystemProxyStatus,
    setSystemProxyIfSafe,
    restorePreviousSystemProxy,
    onBeforeCoreStopTrigger,
    onCoreStartedTrigger,
    onCoreStoppedTrigger,
    startCoreWebsockets,
    stopCoreWebsockets,
  })

  return {
    manager,
    state: { corePid, running, stopping, restarting, coreStateLoading },
    spies: {
      startCore,
      refreshConfig,
      refreshProviderProxies,
      startCoreWebsockets,
      stopCoreWebsockets,
      restoreSystemProxyAfterUnexpectedExit,
    },
  }
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.readFile.mockReset()
  mocks.processInfo.mockReset()
  mocks.removeFile.mockResolvedValue(undefined)
})

describe('checkCoreHealth', () => {
  it('auto-recovers when a running core died while we were asleep', async () => {
    const h: Harness = build()
    h.state.corePid.value = 12345
    h.state.running.value = true

    mocks.readFile.mockResolvedValue('12345')
    mocks.processInfo.mockResolvedValue('NVDisplay.Container')

    await h.manager.checkCoreHealth()

    expect(h.state.running.value).toBe(false)
    expect(h.spies.stopCoreWebsockets).toHaveBeenCalled()
    expect(h.spies.startCore).toHaveBeenCalledWith(undefined, { promptSystemProxy: false })
  })

  it('syncs to running state when an external process started the core', async () => {
    const h: Harness = build()
    h.state.corePid.value = -1
    h.state.running.value = false

    mocks.readFile.mockResolvedValue('9001')
    mocks.processInfo.mockResolvedValue('sing-box')

    await h.manager.checkCoreHealth()

    expect(h.state.running.value).toBe(true)
    expect(h.state.corePid.value).toBe(9001)
    expect(h.spies.startCoreWebsockets).toHaveBeenCalled()
    expect(h.spies.refreshConfig).toHaveBeenCalled()
  })

  it('re-syncs when the pid changed (core was restarted externally)', async () => {
    const h: Harness = build()
    h.state.corePid.value = 100
    h.state.running.value = true

    mocks.readFile.mockResolvedValue('200')
    mocks.processInfo.mockResolvedValue('sing-box')

    await h.manager.checkCoreHealth()

    expect(h.state.corePid.value).toBe(200)
    expect(h.state.running.value).toBe(true)
    expect(h.spies.startCoreWebsockets).toHaveBeenCalled()
  })

  it('does nothing when state is unchanged', async () => {
    const h: Harness = build()
    h.state.corePid.value = 500
    h.state.running.value = true

    mocks.readFile.mockResolvedValue('500')
    mocks.processInfo.mockResolvedValue('sing-box')

    await h.manager.checkCoreHealth()

    expect(h.spies.startCoreWebsockets).not.toHaveBeenCalled()
    expect(h.spies.stopCoreWebsockets).not.toHaveBeenCalled()
    expect(h.spies.startCore).not.toHaveBeenCalled()
  })

  it('skips while the core state is still loading on boot', async () => {
    const h: Harness = build()
    h.state.coreStateLoading.value = true
    mocks.readFile.mockResolvedValue('500')
    mocks.processInfo.mockResolvedValue('sing-box')

    await h.manager.checkCoreHealth()

    expect(mocks.readFile).not.toHaveBeenCalled()
  })

  it('skips while a user-initiated stop is in progress', async () => {
    const h: Harness = build()
    h.state.stopping.value = true
    mocks.readFile.mockResolvedValue('500')

    await h.manager.checkCoreHealth()

    expect(mocks.readFile).not.toHaveBeenCalled()
  })

  it('coalesces concurrent calls into a single probe', async () => {
    const h: Harness = build()
    h.state.corePid.value = -1
    h.state.running.value = false

    let resolveRead: (value: string) => void = () => undefined
    mocks.readFile.mockImplementation(() => new Promise<string>((res) => { resolveRead = res }))
    mocks.processInfo.mockResolvedValue('sing-box')

    const p1 = h.manager.checkCoreHealth()
    const p2 = h.manager.checkCoreHealth()

    resolveRead('9001')
    await Promise.all([p1, p2])

    expect(mocks.readFile).toHaveBeenCalledTimes(1)
  })
})
