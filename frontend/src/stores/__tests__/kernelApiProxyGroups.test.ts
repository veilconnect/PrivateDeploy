import { describe, expect, it, vi } from 'vitest'

vi.mock('@/utils', () => ({
  deepClone: (value: unknown) => JSON.parse(JSON.stringify(value)),
}))

import {
  addCloudNodeToKernelGroups,
  addProxyToKernelGroups,
  removeProxyFromKernelGroups,
} from '../kernelApiProxyGroups'

const proxies = () => ({
  Auto: {
    all: ['sub-1', 'direct'],
    history: [],
    name: 'Auto',
    now: 'sub-1',
    type: 'Selector',
  },
  UrlTest: {
    all: ['direct'],
    history: [],
    name: 'UrlTest',
    now: 'direct',
    type: 'URLTest',
  },
  direct: {
    all: [],
    history: [],
    name: 'direct',
    now: '',
    type: 'Direct',
  },
  'sub-1': {
    all: [],
    history: [],
    name: 'sub-1',
    now: '',
    type: 'Subscription',
  },
} as any)

describe('kernel api proxy group helpers', () => {
  it('removes a subscription from all groups and selects a fallback', () => {
    const original = proxies()
    const updated = removeProxyFromKernelGroups(original, 'sub-1')

    expect(updated['sub-1']).toBeUndefined()
    expect(updated.Auto.all).toEqual(['direct'])
    expect(updated.Auto.now).toBe('direct')
    expect(original.Auto.all).toEqual(['sub-1', 'direct'])
  })

  it('adds a subscription to selector and urltest groups only once', () => {
    const updated = addProxyToKernelGroups(proxies(), 'sub-2')
    const updatedAgain = addProxyToKernelGroups(updated, 'sub-2')

    expect(updated['sub-2']).toMatchObject({ name: 'sub-2', type: 'Subscription' })
    expect(updatedAgain.Auto.all.filter((item: string) => item === 'sub-2')).toHaveLength(1)
    expect(updatedAgain.UrlTest.all).toContain('sub-2')
    expect(updatedAgain.direct.all).not.toContain('sub-2')
  })

  it('adds cloud node protocol tags for public IPv4 and IPv6 addresses', () => {
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => undefined)
    const updated = addCloudNodeToKernelGroups(proxies(), {
      hysteriaPassword: 'secret',
      hysteriaPort: 443,
      ipv4: '203.0.113.10',
      ipv6: '2001:db8::10',
      label: 'sg-edge',
      ssPassword: 'secret',
      ssPort: 8388,
      trojanPassword: 'secret',
      trojanPort: 8443,
      vlessPort: 443,
      vlessPublicKey: 'pub',
      vlessShortId: 'sid',
      vlessUUID: 'uuid',
    })

    expect(Object.keys(updated)).toEqual(expect.arrayContaining([
      'sg-edge-ss-v4',
      'sg-edge-ss-v6',
      'sg-edge-hysteria2-v4',
      'sg-edge-vless-v6',
      'sg-edge-trojan-v4',
    ]))
    expect(updated.Auto.all).toEqual(expect.arrayContaining(['sg-edge-ss-v4', 'sg-edge-vless-v6']))
    logSpy.mockRestore()
  })

  it('skips cloud nodes without usable public addresses', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => undefined)
    const original = proxies()
    const updated = addCloudNodeToKernelGroups(original, {
      ipv4: '10.0.0.2',
      label: 'private-node',
      ssPassword: 'secret',
      ssPort: 8388,
    })

    expect(updated).toEqual(original)
    expect(warnSpy).toHaveBeenCalledWith('[KernelApi] Node private-node has no usable public IP, skipping')
    warnSpy.mockRestore()
  })
})
