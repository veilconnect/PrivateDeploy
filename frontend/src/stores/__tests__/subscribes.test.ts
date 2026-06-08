import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { stringify } from 'yaml'

import { RequestMethod } from '@/enums/app'

const mocks = vi.hoisted(() => ({
  asyncFunction: vi.fn(),
  onSubscribeTrigger: vi.fn(),
  readFile: vi.fn(),
  requests: vi.fn(),
  sampleID: vi.fn(),
  writeFile: vi.fn(),
}))

vi.mock('@/bridge', () => ({
  ReadFile: mocks.readFile,
  Requests: mocks.requests,
  WriteFile: mocks.writeFile,
}))

vi.mock('@/stores', () => ({
  usePluginsStore: () => ({
    onSubscribeTrigger: mocks.onSubscribeTrigger,
  }),
}))

vi.mock('@/utils', () => ({
  asyncPool: async (_limit: number, list: unknown[], iterator: (item: unknown) => Promise<void>) => {
    for (const item of list) await iterator(item)
  },
  debounce: (fn: (...args: unknown[]) => unknown) => fn,
  ignoredError: async (fn: (...args: unknown[]) => Promise<unknown>, ...args: unknown[]) => {
    try {
      return await fn(...args)
    } catch {
      return undefined
    }
  },
  isValidBase64: () => false,
  isValidSubJson: (body: string) => {
    try {
      return Array.isArray(JSON.parse(body).outbounds)
    } catch {
      return false
    }
  },
  isValidSubYAML: () => false,
  omitArray: (list: Record<string, unknown>[], keys: string[]) =>
    list.map((item) => Object.fromEntries(Object.entries(item).filter(([key]) => !keys.includes(key)))),
  sampleID: mocks.sampleID,
}))

import { useSubscribesStore } from '../subscribes'

import type { Subscription } from '@/types/app'

const subscription = (overrides: Partial<Subscription> = {}): Subscription => ({
  disabled: false,
  download: 0,
  exclude: '',
  excludeProtocol: '',
  expire: 0,
  header: {
    request: {},
    response: {},
  },
  id: 'sub-1',
  inSecure: false,
  include: '',
  includeProtocol: '',
  name: 'Subscription 1',
  path: 'data/subscribes/sub-1.json',
  proxies: [],
  proxyPrefix: '',
  requestMethod: RequestMethod.Get,
  script: 'async function onSubscribe(proxies, subscription) { return { proxies, subscription } }',
  total: 0,
  type: 'Http',
  updateTime: 0,
  upload: 0,
  url: 'https://sub.test/list',
  website: '',
  ...overrides,
})

describe('subscribes store', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    setActivePinia(createPinia())

    mocks.onSubscribeTrigger.mockImplementation(async (proxies) => proxies)
    mocks.readFile.mockRejectedValue(new Error('missing'))
    mocks.requests.mockResolvedValue({
      body: JSON.stringify({
        outbounds: [
          { tag: 'HK 1', type: 'ss' },
          { tag: 'US 1', type: 'vmess' },
        ],
      }),
      headers: {
        'Subscription-Userinfo': 'upload=10; download=20; total=100; expire=200',
      },
    })
    mocks.sampleID
      .mockReturnValueOnce('sub-id')
      .mockReturnValueOnce('proxy-id-1')
      .mockReturnValueOnce('proxy-id-2')
      .mockReturnValue('proxy-next')
    mocks.writeFile.mockResolvedValue(undefined)

    function AsyncFunctionMock(source: string) {
      mocks.asyncFunction(source)
      return async () => ({
        proxies: [{ tag: 'Final HK', type: 'ss' }],
        subscription: { name: 'Updated subscription' },
      })
    }
    Object.defineProperty(window, 'AsyncFunction', {
      configurable: true,
      value: AsyncFunctionMock,
    })
  })

  it('loads and migrates legacy subscription fields', async () => {
    mocks.readFile.mockResolvedValueOnce(stringify([
      {
        disabled: false,
        download: 0,
        exclude: '',
        excludeProtocol: '',
        expire: 0,
        id: 'legacy',
        include: '',
        includeProtocol: '',
        inSecure: false,
        name: 'Legacy',
        path: 'data/subscribes/legacy.json',
        proxies: [],
        proxyPrefix: '',
        total: 0,
        type: 'Http',
        updateTime: 0,
        upload: 0,
        url: 'https://legacy.test',
        userAgent: 'PrivateDeploy',
        website: '',
      },
    ]))

    const store = useSubscribesStore()
    await store.setupSubscribes()

    expect(store.subscribes[0]).toMatchObject({
      header: { request: { 'User-Agent': 'PrivateDeploy' }, response: {} },
      requestMethod: RequestMethod.Get,
      script: expect.stringContaining('onSubscribe'),
    })
    expect(mocks.writeFile).toHaveBeenCalledWith('data/subscribes.yaml', expect.any(String))
  })

  it('imports, edits, deletes, and rolls back failed writes', async () => {
    const store = useSubscribesStore()

    await store.importSubscribe('Imported', 'https://sub.test/imported')

    expect(store.getSubscribeById('sub-id')).toMatchObject({
      id: 'sub-id',
      name: 'Imported',
      path: 'data/subscribes/sub-id.json',
      requestMethod: RequestMethod.Get,
      url: 'https://sub.test/imported',
    })

    await store.editSubscribe('sub-id', subscription({ id: 'sub-id', name: 'Edited' }))
    expect(store.getSubscribeById('sub-id')?.name).toBe('Edited')

    mocks.writeFile.mockRejectedValueOnce(new Error('disk full'))
    await expect(store.deleteSubscribe('sub-id')).rejects.toThrow('disk full')
    expect(store.getSubscribeById('sub-id')?.name).toBe('Edited')
  })

  it('updates HTTP subscriptions through plugin and script transforms', async () => {
    vi.spyOn(Date, 'now').mockReturnValue(1000)
    const store = useSubscribesStore()
    const sub = subscription({
      exclude: 'US',
      include: 'HK|US',
      includeProtocol: 'ss|vmess',
      proxyPrefix: 'PD - ',
    })
    store.subscribes.push(sub)

    await expect(store.updateSubscribe('sub-1')).resolves.toBe(
      'Subscription [Updated subscription] updated successfully.',
    )

    expect(mocks.requests).toHaveBeenCalledWith({
      autoTransformBody: false,
      headers: {},
      method: RequestMethod.Get,
      options: { Insecure: false },
      url: 'https://sub.test/list',
    })
    expect(mocks.onSubscribeTrigger).toHaveBeenCalledWith(
      [
        { tag: 'PD - HK 1', type: 'ss' },
        { tag: 'US 1', type: 'vmess' },
      ],
      expect.objectContaining({ id: 'sub-1' }),
    )
    expect(mocks.asyncFunction.mock.calls[0][0]).toContain('PD - HK 1')
    expect(sub).toMatchObject({
      download: 20,
      expire: 200000,
      name: 'Updated subscription',
      total: 100,
      upload: 10,
      updateTime: 1000,
    })
    expect(sub.proxies).toEqual([{ id: 'proxy-id-2', tag: 'Final HK', type: 'ss' }])
    expect(mocks.writeFile).toHaveBeenCalledWith(
      'data/subscribes/sub-1.json',
      JSON.stringify([{ tag: 'Final HK', type: 'ss' }], null, 2),
    )
  })

  it('reports missing and disabled subscriptions and updates enabled subscriptions in bulk', async () => {
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    const store = useSubscribesStore()
    store.subscribes.push(subscription(), subscription({ disabled: true, id: 'disabled', name: 'Disabled' }))

    await expect(store.updateSubscribe('missing')).rejects.toBe('missing Not Found')
    await expect(store.updateSubscribe('disabled')).rejects.toBe('Disabled Disabled')

    await store.updateSubscribes()

    expect(mocks.requests).toHaveBeenCalledTimes(1)
    expect(store.getSubscribeById('disabled')?.updating).toBeUndefined()
    errorSpy.mockRestore()
  })
})
