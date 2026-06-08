import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  confirm: vi.fn(),
  message: {
    error: vi.fn(),
    info: vi.fn(),
    success: vi.fn(),
    warn: vi.fn(),
  },
  appSettingsStore: {
    app: {
      autoSetSystemProxy: false,
      systemProxyPolicyInitialized: false,
    },
  },
  envStore: {
    capabilities: {
      systemProxySupported: true,
    },
    systemProxyState: 'disabled',
    restorePreviousSystemProxy: vi.fn(),
    setSystemProxyIfSafe: vi.fn(),
    updateSystemProxyStatus: vi.fn(),
  },
  kernelApiStore: {
    running: false,
  },
}))

vi.mock('@/stores', () => ({
  useAppSettingsStore: () => mocks.appSettingsStore,
  useEnvStore: () => mocks.envStore,
  useKernelApiStore: () => mocks.kernelApiStore,
}))

vi.mock('@/utils', () => ({
  confirm: mocks.confirm,
  message: mocks.message,
}))

import { useSystemProxyControl } from './useSystemProxyControl'

describe('useSystemProxyControl', () => {
  beforeEach(() => {
    vi.clearAllMocks()

    mocks.appSettingsStore.app.autoSetSystemProxy = false
    mocks.appSettingsStore.app.systemProxyPolicyInitialized = false
    mocks.envStore.capabilities.systemProxySupported = true
    mocks.envStore.systemProxyState = 'disabled'
    mocks.envStore.restorePreviousSystemProxy.mockResolvedValue(true)
    mocks.envStore.setSystemProxyIfSafe.mockResolvedValue(true)
    mocks.envStore.updateSystemProxyStatus.mockResolvedValue(false)
    mocks.kernelApiStore.running = false
  })

  it('enables automation from settings without prompting again', async () => {
    const { setAutomationEnabled } = useSystemProxyControl()

    const enabled = await setAutomationEnabled(true, { forcePrompt: false })

    expect(enabled).toBe(true)
    expect(mocks.confirm).not.toHaveBeenCalled()
    expect(mocks.appSettingsStore.app.autoSetSystemProxy).toBe(true)
    expect(mocks.appSettingsStore.app.systemProxyPolicyInitialized).toBe(true)
  })

  it('restores the previous proxy when automation is disabled', async () => {
    mocks.appSettingsStore.app.autoSetSystemProxy = true
    mocks.appSettingsStore.app.systemProxyPolicyInitialized = true
    mocks.confirm.mockResolvedValue(undefined)

    const { setAutomationEnabled } = useSystemProxyControl()

    const enabled = await setAutomationEnabled(false)

    expect(enabled).toBe(false)
    expect(mocks.envStore.restorePreviousSystemProxy).toHaveBeenCalledWith(true)
    expect(mocks.appSettingsStore.app.autoSetSystemProxy).toBe(false)
  })

  it('keeps automation enabled when the disable confirmation is cancelled', async () => {
    mocks.appSettingsStore.app.autoSetSystemProxy = true
    mocks.appSettingsStore.app.systemProxyPolicyInitialized = true
    mocks.confirm.mockRejectedValue(new Error('cancelled'))

    const { setAutomationEnabled } = useSystemProxyControl()

    const enabled = await setAutomationEnabled(false)

    expect(enabled).toBe(true)
    expect(mocks.envStore.restorePreviousSystemProxy).not.toHaveBeenCalled()
    expect(mocks.appSettingsStore.app.autoSetSystemProxy).toBe(true)
  })
})
