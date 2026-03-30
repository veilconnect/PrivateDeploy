import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  confirm: vi.fn(),
  message: {
    error: vi.fn(),
    info: vi.fn(),
    success: vi.fn(),
    warn: vi.fn(),
  },
}))

vi.mock('@/utils', () => ({
  confirm: mocks.confirm,
  message: mocks.message,
}))

import {
  enableSystemProxyAutomation,
  maybePromptToEnableSystemProxyBeforeConnect,
  type SystemProxyControlDeps,
} from './systemProxyControlCore'

const createDeps = (): SystemProxyControlDeps => ({
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
    restorePreviousSystemProxy: vi.fn().mockResolvedValue(true),
    setSystemProxyIfSafe: vi.fn().mockResolvedValue(true),
    updateSystemProxyStatus: vi.fn().mockResolvedValue(false),
  },
})

describe('systemProxyControlCore', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('prompts and initializes policy before connect when it is still unset', async () => {
    const deps = createDeps()
    mocks.confirm.mockResolvedValue(undefined)

    const enabled = await maybePromptToEnableSystemProxyBeforeConnect(deps)

    expect(enabled).toBe(true)
    expect(mocks.confirm).toHaveBeenCalledTimes(1)
    expect(deps.appSettingsStore.app.autoSetSystemProxy).toBe(true)
    expect(deps.appSettingsStore.app.systemProxyPolicyInitialized).toBe(true)
  })

  it('skips the prompt when policy was already initialized', async () => {
    const deps = createDeps()
    deps.appSettingsStore.app.systemProxyPolicyInitialized = true

    const enabled = await maybePromptToEnableSystemProxyBeforeConnect(deps)

    expect(enabled).toBe(false)
    expect(mocks.confirm).not.toHaveBeenCalled()
  })

  it('applies the system proxy immediately when enabling automation while kernel is running', async () => {
    const deps = createDeps()

    const enabled = await enableSystemProxyAutomation(deps, {
      forcePrompt: false,
      kernelRunning: true,
    })

    expect(enabled).toBe(true)
    expect(deps.envStore.setSystemProxyIfSafe).toHaveBeenCalledTimes(1)
  })
})
