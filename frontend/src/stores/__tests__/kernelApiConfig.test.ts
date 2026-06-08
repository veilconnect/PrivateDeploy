import { beforeEach, describe, expect, it, vi } from 'vitest'
import { ref } from 'vue'

import { Inbound, TunStack } from '@/enums/kernel'

const mocks = vi.hoisted(() => ({
  getConfigs: vi.fn(),
  readFile: vi.fn(),
  restoreProfile: vi.fn(),
  restartCore: vi.fn(),
  setConfigs: vi.fn(),
  updateSystemProxyStatus: vi.fn(),
}))

vi.mock('@/api/kernel', () => ({
  getConfigs: mocks.getConfigs,
  setConfigs: mocks.setConfigs,
}))

vi.mock('@/bridge', () => ({
  ReadFile: mocks.readFile,
}))

vi.mock('@/utils', () => ({
  deepClone: (value: unknown) => JSON.parse(JSON.stringify(value)),
  restoreProfile: mocks.restoreProfile,
}))

import { createKernelApiConfigManager } from '../kernelApiConfig'

const listen = (listenPort: number, listenAddress = '127.0.0.1') => ({
  listen: listenAddress,
  listen_port: listenPort,
})

const inbound = (type: Inbound, port: number, listenAddress = '127.0.0.1') => ({
  enable: true,
  id: `${type}-runtime`,
  tag: `${type}-in`,
  type,
  [type]: {
    listen: listen(port, listenAddress),
  },
})

const runtimeProfile = () => ({
  dns: { rules: [] },
  experimental: { clash_api: { external_controller: '127.0.0.1:20123', secret: '' } },
  id: 'runtime',
  inbounds: [
    inbound(Inbound.Mixed, 7890, '0.0.0.0'),
    inbound(Inbound.Http, 7891),
    inbound(Inbound.Socks, 7892),
    {
      enable: true,
      id: 'tun-runtime',
      tag: 'tun-in',
      tun: {
        interface_name: 'utun9',
        stack: TunStack.GVisor,
      },
      type: Inbound.Tun,
    },
  ],
  mixin: 'runtime-mixin',
  outbounds: [],
  route: {
    auto_detect_interface: false,
    default_interface: 'eth0',
    rule_set: [],
    rules: [],
  },
  script: '',
}) as unknown as IProfile

const selectedProfile = () => ({
  ...runtimeProfile(),
  dns: { rules: [{ id: 'dns-rule' }] },
  experimental: { clash_api: { external_controller: '127.0.0.1:9090', secret: 'secret' } },
  id: 'selected',
  inbounds: [
    { ...inbound(Inbound.Mixed, 7890), id: 'mixed-selected' },
    { ...inbound(Inbound.Http, 7891), id: 'http-selected' },
    { ...inbound(Inbound.Socks, 7892), id: 'socks-selected' },
    {
      enable: true,
      id: 'tun-selected',
      tag: 'tun-in',
      tun: { interface_name: 'utun9', stack: TunStack.GVisor },
      type: Inbound.Tun,
    },
  ],
  mixin: 'selected-mixin',
  outbounds: [{ id: 'outbound-1' }],
  route: { auto_detect_interface: false, default_interface: 'eth0', rule_set: [], rules: [{ id: 'route-rule' }] },
  script: 'selected-script',
}) as unknown as IProfile

describe('kernel api config manager', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mocks.getConfigs.mockResolvedValue({
      mode: 'rule',
      port: 0,
      'mixed-port': 0,
      'socks-port': 0,
      tun: { device: '', enable: false, stack: '' },
    })
    mocks.readFile.mockResolvedValue('{}')
    mocks.restoreProfile.mockReturnValue(runtimeProfile())
    mocks.restartCore.mockResolvedValue(undefined)
    mocks.setConfigs.mockResolvedValue(undefined)
    mocks.updateSystemProxyStatus.mockResolvedValue(undefined)
  })

  it('refreshes config from the REST API and reconstructed runtime profile', async () => {
    const config = ref<any>({
      mode: '',
      port: 0,
      'mixed-port': 0,
      'socks-port': 0,
      tun: { device: 'old', enable: false, stack: '' },
    })
    let runtime: IProfile | undefined
    const manager = createKernelApiConfigManager({
      config,
      getRuntimeProfile: () => runtime,
      getSelectedProfile: selectedProfile,
      restartCore: mocks.restartCore,
      setRuntimeProfile: (profile) => {
        runtime = profile
      },
      updateSystemProxyStatus: mocks.updateSystemProxyStatus,
    })

    await manager.refreshConfig()

    expect(mocks.readFile).toHaveBeenCalledWith('data/sing-box/config.json')
    expect(config.value).toMatchObject({
      'allow-lan': true,
      'interface-name': 'eth0',
      'mixed-port': 7890,
      mode: 'rule',
      port: 7891,
      'socks-port': 7892,
      tun: {
        device: 'utun9',
        enable: true,
        stack: TunStack.GVisor,
      },
    })
    expect(runtime?.id).toBe('selected')
    expect(runtime?.inbounds.find((item) => item.type === Inbound.Mixed)?.id).toBe('mixed-selected')
    expect(runtime?.outbounds).toEqual([{ id: 'outbound-1' }])
  })

  it('updates mode through the API and mutates runtime inbounds before restarting', async () => {
    const config = ref<any>({
      mode: 'rule',
      port: 7891,
      'mixed-port': 7890,
      'socks-port': 7892,
      tun: { device: 'utun9', enable: true, stack: TunStack.GVisor },
    })
    let runtime = runtimeProfile()
    const manager = createKernelApiConfigManager({
      config,
      getRuntimeProfile: () => runtime,
      getSelectedProfile: selectedProfile,
      restartCore: mocks.restartCore,
      setRuntimeProfile: (profile) => {
        runtime = profile!
      },
      updateSystemProxyStatus: mocks.updateSystemProxyStatus,
    })

    await manager.updateConfig('mode', 'global')
    expect(mocks.setConfigs).toHaveBeenCalledWith({ mode: 'global' })

    await manager.updateConfig('mixed', 0)
    expect(runtime.inbounds.find((item) => item.type === Inbound.Mixed)?.enable).toBe(false)

    await manager.updateConfig('http', 8080)
    expect((runtime.inbounds.find((item) => item.type === Inbound.Http) as any).http.listen.listen_port).toBe(8080)

    await manager.updateConfig('allow-lan', false)
    expect((runtime.inbounds.find((item) => item.type === Inbound.Http) as any).http.listen.listen).toBe('127.0.0.1')

    await manager.updateConfig('tun', {
      device: 'utun10',
      enable: false,
      interface_name: 'en0',
      stack: TunStack.Mixed,
    })
    const tun = runtime.inbounds.find((item) => item.type === Inbound.Tun) as any
    expect(tun.enable).toBe(false)
    expect(tun.tun.interface_name).toBe('utun10')
    expect(runtime.route.default_interface).toBe('en0')
    expect(runtime.route.auto_detect_interface).toBe(false)
    expect(mocks.restartCore).toHaveBeenCalled()
    expect(mocks.updateSystemProxyStatus).toHaveBeenCalled()
  })

  it('returns the preferred proxy port in mixed, http, socks order', () => {
    const config = ref<any>({
      port: 7891,
      'mixed-port': 7890,
      'socks-port': 7892,
      tun: {},
    })
    const manager = createKernelApiConfigManager({
      config,
      getRuntimeProfile: () => undefined,
      getSelectedProfile: () => undefined,
      restartCore: mocks.restartCore,
      setRuntimeProfile: vi.fn(),
      updateSystemProxyStatus: mocks.updateSystemProxyStatus,
    })

    expect(manager.getProxyPort()).toEqual({ port: 7890, proxyType: 'mixed' })
    config.value['mixed-port'] = 0
    expect(manager.getProxyPort()).toEqual({ port: 7891, proxyType: 'http' })
    config.value.port = 0
    expect(manager.getProxyPort()).toEqual({ port: 7892, proxyType: 'socks' })
    config.value['socks-port'] = 0
    expect(manager.getProxyPort()).toBeUndefined()
  })
})
