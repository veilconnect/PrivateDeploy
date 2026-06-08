import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  getEnv: vi.fn(),
  getSystemProxy: vi.fn(),
  setSystemProxy: vi.fn(),
  updateTrayMenus: vi.fn(),
  appSettingsStore: {
    app: {
      systemProxyBackup: '',
      systemProxyManaged: false,
    },
  },
  kernelApiStore: {
    config: {
      port: 7890,
      'mixed-port': 7891,
      'socks-port': 7892,
    },
    getProxyPort: vi.fn(),
  },
}))

vi.mock('@/bridge', () => ({
  GetEnv: mocks.getEnv,
}))

vi.mock('@/utils', () => ({
  GetSystemProxy: mocks.getSystemProxy,
  SetSystemProxy: mocks.setSystemProxy,
  updateTrayMenus: mocks.updateTrayMenus,
}))

vi.mock('@/stores', () => ({
  useAppSettingsStore: () => mocks.appSettingsStore,
  useKernelApiStore: () => mocks.kernelApiStore,
}))

import { useEnvStore } from '@/stores/env'

const setupEnvStore = async () => {
  setActivePinia(createPinia())
  const envStore = useEnvStore()
  await envStore.setupEnv()
  return envStore
}

describe('env system proxy lifecycle', () => {
  beforeEach(() => {
    vi.clearAllMocks()

    mocks.getEnv.mockResolvedValue({
      appName: 'PrivateDeploy',
      appVersion: 'test',
      basePath: '/tmp/pd-test',
      os: 'linux',
      arch: 'amd64',
      capabilities: {
        systemProxySupported: true,
      },
    })

    mocks.getSystemProxy.mockResolvedValue('')
    mocks.setSystemProxy.mockResolvedValue(undefined)
    mocks.kernelApiStore.getProxyPort.mockReturnValue({
      port: 7891,
      proxyType: 'mixed',
    })
    mocks.appSettingsStore.app.systemProxyBackup = ''
    mocks.appSettingsStore.app.systemProxyManaged = false
  })

  it('marks an existing non-app proxy as external', async () => {
    mocks.getSystemProxy.mockResolvedValue('http://corp.proxy.local:8080')

    const envStore = await setupEnvStore()
    await envStore.updateSystemProxyStatus()

    expect(envStore.systemProxy).toBe(false)
    expect(envStore.systemProxyState).toBe('external')
    expect(envStore.systemProxyServer).toBe('http://corp.proxy.local:8080')
  })

  it('does not override an existing external proxy in safe mode', async () => {
    mocks.getSystemProxy.mockResolvedValue('http://corp.proxy.local:8080')

    const envStore = await setupEnvStore()
    const applied = await envStore.setSystemProxyIfSafe()

    expect(applied).toBe(false)
    expect(mocks.setSystemProxy).not.toHaveBeenCalled()
    expect(mocks.appSettingsStore.app.systemProxyBackup).toBe('')
  })

  it('restores the previous proxy after an unexpected exit', async () => {
    mocks.appSettingsStore.app.systemProxyManaged = true
    mocks.appSettingsStore.app.systemProxyBackup = 'socks=10.0.0.2:1080'
    mocks.getSystemProxy
      .mockResolvedValueOnce('http://127.0.0.1:7891')
      .mockResolvedValueOnce('socks=10.0.0.2:1080')

    const envStore = await setupEnvStore()
    const restored = await envStore.restoreSystemProxyAfterUnexpectedExit()

    expect(restored).toBe(true)
    expect(mocks.setSystemProxy).toHaveBeenCalledWith(true, '10.0.0.2:1080', 'socks')
    expect(mocks.appSettingsStore.app.systemProxyManaged).toBe(false)
    expect(mocks.appSettingsStore.app.systemProxyBackup).toBe('')
    expect(envStore.systemProxyState).toBe('external')
    expect(envStore.systemProxyServer).toBe('socks=10.0.0.2:1080')
  })

  it('restores the previous proxy on a normal stop', async () => {
    mocks.appSettingsStore.app.systemProxyManaged = true
    mocks.appSettingsStore.app.systemProxyBackup = 'http://corp.proxy.local:8080'
    mocks.getSystemProxy.mockResolvedValue('http://corp.proxy.local:8080')

    const envStore = await setupEnvStore()
    const restored = await envStore.restorePreviousSystemProxy(true)

    expect(restored).toBe(true)
    expect(mocks.setSystemProxy).toHaveBeenCalledWith(true, 'corp.proxy.local:8080', 'http')
    expect(mocks.appSettingsStore.app.systemProxyManaged).toBe(false)
    expect(mocks.appSettingsStore.app.systemProxyBackup).toBe('')
    expect(envStore.systemProxyState).toBe('external')
    expect(envStore.systemProxyServer).toBe('http://corp.proxy.local:8080')
  })

  it('clears the app-managed proxy on a normal stop when no backup exists', async () => {
    mocks.appSettingsStore.app.systemProxyManaged = true
    mocks.getSystemProxy.mockResolvedValue('')

    const envStore = await setupEnvStore()
    const restored = await envStore.restorePreviousSystemProxy(true)

    expect(restored).toBe(true)
    expect(mocks.setSystemProxy).toHaveBeenCalledWith(false, '')
    expect(mocks.appSettingsStore.app.systemProxyManaged).toBe(false)
    expect(mocks.appSettingsStore.app.systemProxyBackup).toBe('')
    expect(envStore.systemProxyState).toBe('disabled')
    expect(envStore.systemProxyServer).toBe('')
  })

  it('clears stale managed state when the system proxy is already external', async () => {
    mocks.appSettingsStore.app.systemProxyManaged = true
    mocks.appSettingsStore.app.systemProxyBackup = 'http://corp.proxy.local:8080'
    mocks.getSystemProxy.mockResolvedValue('http://corp.proxy.local:8080')

    const envStore = await setupEnvStore()
    const restored = await envStore.restoreSystemProxyAfterUnexpectedExit()

    expect(restored).toBe(false)
    expect(mocks.setSystemProxy).not.toHaveBeenCalled()
    expect(mocks.appSettingsStore.app.systemProxyManaged).toBe(false)
    expect(mocks.appSettingsStore.app.systemProxyBackup).toBe('')
    expect(envStore.systemProxyState).toBe('external')
    expect(envStore.systemProxyServer).toBe('http://corp.proxy.local:8080')
  })
})
