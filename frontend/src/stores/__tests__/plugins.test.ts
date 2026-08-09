// Focused tests for the plugin full-trust consent gate: adding a plugin
// (Plugin-Hub install or manual form) must first present the informed-consent
// dialog explaining that plugins run as fully trusted, unsandboxed code, and
// a declined dialog must abort the add before any code is fetched or pinned.
// Plugins persisted before the consent mechanism existed (records without a
// trustConsentVersion field) must see the same dialog before their first
// execution, and a decline must keep them from running.
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { stringify } from 'yaml'

import { PluginsFilePath } from '@/constant/app'
import { PluginHubFilePath } from '@/constant/app'
import { PluginTrigger, PluginTriggerEvent } from '@/enums/app'

const mocks = vi.hoisted(() => ({
  confirm: vi.fn(),
  httpGet: vi.fn(),
  readFile: vi.fn(),
  removeFile: vi.fn(),
  writeFile: vi.fn(),
}))

vi.mock('@/bridge', () => ({
  HttpGet: mocks.httpGet,
  ReadFile: mocks.readFile,
  RemoveFile: mocks.removeFile,
  WriteFile: mocks.writeFile,
}))

vi.mock('@/stores', () => ({
  useAppSettingsStore: () => ({
    app: { pluginSettings: {}, addPluginToMenu: false },
  }),
}))

vi.mock('@/utils', () => ({
  asyncPool: async (_n: number, items: any[], fn: (item: any) => Promise<void>) => {
    for (const item of items) await fn(item)
  },
  confirm: mocks.confirm,
  debounce: (fn: any) => fn,
  deepClone: (v: any) => JSON.parse(JSON.stringify(v)),
  ignoredError: async (fn: any, ...args: any[]) => {
    try {
      return await fn(...args)
    } catch {
      return undefined
    }
  },
  isNumber: (v: any) => typeof v === 'number',
  omitArray: (arr: any[], keys: string[]) =>
    arr.map((item) => {
      const copy = { ...item }
      keys.forEach((k) => delete copy[k])
      return copy
    }),
  updateTrayMenus: vi.fn(),
}))

import { STARTUP_PLUGIN_EXECUTION_TIMEOUT_MS, usePluginsStore } from '../plugins'
import {
  PLUGIN_FULL_TRUST_ACCEPT_KEY,
  PLUGIN_FULL_TRUST_TITLE_KEY,
  PLUGIN_FULL_TRUST_WARNING_KEY,
  PLUGIN_TRUST_CONSENT_VERSION,
} from '../pluginSecurity'

import type { Plugin } from '@/types/app'

const makePlugin = (overrides: Partial<Plugin> = {}): Plugin =>
  ({
    id: 'user-plugin-1',
    version: 'v1.0.0',
    name: 'Test Plugin',
    description: 'test',
    type: 'Http',
    url: 'https://raw.githubusercontent.com/a/b/main/plugin.js',
    path: 'data/plugins/user-plugin-1.js',
    triggers: [PluginTrigger.OnManual],
    tags: [],
    hasUI: false,
    menus: {},
    context: {
      profiles: {},
      subscriptions: {},
      rulesets: {},
      plugins: {},
      scheduledtasks: {},
    },
    configuration: [],
    disabled: false,
    install: false,
    installed: false,
    status: 0,
    ...overrides,
  }) as Plugin

describe('usePluginsStore addPlugin full-trust consent', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    mocks.confirm.mockReset()
    mocks.httpGet.mockReset()
    mocks.readFile.mockReset()
    mocks.writeFile.mockReset()
    mocks.httpGet.mockResolvedValue({ status: 200, headers: {}, body: 'const onRun = 1' })
    mocks.writeFile.mockResolvedValue(undefined)
  })

  it('shows the full-trust warning dialog before installing', async () => {
    mocks.confirm.mockResolvedValue(true)
    const store = usePluginsStore()

    await store.addPlugin(makePlugin())

    expect(mocks.confirm).toHaveBeenCalledWith(
      PLUGIN_FULL_TRUST_TITLE_KEY,
      PLUGIN_FULL_TRUST_WARNING_KEY,
      expect.objectContaining({ type: 'text' }),
    )
    // Consent must come BEFORE the plugin code is fetched.
    const confirmOrder = mocks.confirm.mock.invocationCallOrder[0]
    const fetchOrder = mocks.httpGet.mock.invocationCallOrder[0]
    expect(confirmOrder).toBeLessThan(fetchOrder)
    expect(store.plugins).toHaveLength(1)
    // Code was pinned (TOFU) after consent.
    expect(store.plugins[0].codeHash).toMatch(/^[0-9a-f]{64}$/)
  })

  it('ignores a malicious consent marker supplied by Plugin-Hub metadata', async () => {
    mocks.confirm.mockResolvedValue(true)
    const store = usePluginsStore()
    const plugin = makePlugin() as Plugin & { trustConsentVersion?: number }
    plugin.trustConsentVersion = PLUGIN_TRUST_CONSENT_VERSION + 999

    await store.addPlugin(plugin)

    expect(mocks.confirm).toHaveBeenCalledTimes(1)
    expect(mocks.confirm.mock.invocationCallOrder[0]).toBeLessThan(
      mocks.httpGet.mock.invocationCallOrder[0],
    )
    expect((store.plugins[0] as any).trustConsentVersion).toBe(PLUGIN_TRUST_CONSENT_VERSION)
  })

  it('declining the warning aborts the add and fetches nothing', async () => {
    mocks.confirm.mockRejectedValue('canceled')
    const store = usePluginsStore()

    await expect(store.addPlugin(makePlugin())).rejects.toBeTruthy()

    expect(store.plugins).toHaveLength(0)
    expect(mocks.httpGet).not.toHaveBeenCalled()
    expect(mocks.writeFile).not.toHaveBeenCalled()
  })

  it('a dismissed (falsy) confirmation also aborts', async () => {
    mocks.confirm.mockResolvedValue(false)
    const store = usePluginsStore()

    await expect(store.addPlugin(makePlugin())).rejects.toBeTruthy()

    expect(store.plugins).toHaveLength(0)
    expect(mocks.httpGet).not.toHaveBeenCalled()
  })

  it('passes the accept okText and the full warning body to the dialog', async () => {
    mocks.confirm.mockResolvedValue(true)
    const store = usePluginsStore()

    await store.addPlugin(makePlugin())

    expect(mocks.confirm).toHaveBeenCalledWith(
      PLUGIN_FULL_TRUST_TITLE_KEY,
      PLUGIN_FULL_TRUST_WARNING_KEY,
      { type: 'text', okText: PLUGIN_FULL_TRUST_ACCEPT_KEY },
    )
  })

  it('records the confirmed consent version so the dialog is one-time', async () => {
    mocks.confirm.mockResolvedValue(true)
    const store = usePluginsStore()

    await store.addPlugin(makePlugin())

    expect((store.plugins[0] as any).trustConsentVersion).toBe(PLUGIN_TRUST_CONSENT_VERSION)
    // ...and it is persisted with the plugin config.
    const saved = mocks.writeFile.mock.calls.find(([path]) => path === PluginsFilePath)
    expect(saved).toBeTruthy()
    expect(saved![1]).toContain(`trustConsentVersion: ${PLUGIN_TRUST_CONSENT_VERSION}`)
  })

  it('the File-plugin form path goes through the same consent dialog', async () => {
    mocks.confirm.mockResolvedValue(true)
    mocks.readFile.mockResolvedValue('const onRun = 1')
    const store = usePluginsStore()

    await store.addPlugin(
      makePlugin({ id: 'user-file-plugin', type: 'File', url: '', path: 'data/plugins/f.js' }),
    )

    expect(mocks.confirm).toHaveBeenCalledWith(
      PLUGIN_FULL_TRUST_TITLE_KEY,
      PLUGIN_FULL_TRUST_WARNING_KEY,
      { type: 'text', okText: PLUGIN_FULL_TRUST_ACCEPT_KEY },
    )
    expect(mocks.httpGet).not.toHaveBeenCalled()
    expect(store.plugins).toHaveLength(1)
    expect((store.plugins[0] as any).trustConsentVersion).toBe(PLUGIN_TRUST_CONSENT_VERSION)
  })

  it('a declined File-plugin add installs nothing and reads no code', async () => {
    mocks.confirm.mockRejectedValue('canceled')
    const store = usePluginsStore()

    await expect(
      store.addPlugin(
        makePlugin({ id: 'user-file-plugin', type: 'File', url: '', path: 'data/plugins/f.js' }),
      ),
    ).rejects.toBeTruthy()

    expect(store.plugins).toHaveLength(0)
    expect(mocks.readFile).not.toHaveBeenCalled()
  })
})

describe('usePluginsStore strips consent fields from Plugin-Hub metadata', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    mocks.confirm.mockReset()
    mocks.httpGet.mockReset()
    mocks.readFile.mockReset()
    mocks.writeFile.mockReset()
    mocks.writeFile.mockResolvedValue(undefined)
  })

  it('strips a marker from the cached Hub file', async () => {
    const cached = makePlugin({ id: 'plugin-hostile' }) as Plugin & {
      trustConsentVersion?: number
    }
    cached.trustConsentVersion = 999
    mocks.readFile.mockImplementation(async (path: string) => {
      if (path === PluginHubFilePath) return JSON.stringify([cached])
      throw 'not found'
    })

    const store = usePluginsStore()
    await store.setupPlugins()

    expect((store.pluginHub[0] as any).trustConsentVersion).toBeUndefined()
  })

  it('strips and never persists a marker from a remote Hub response', async () => {
    const remote = makePlugin({ id: 'plugin-hostile' }) as Plugin & {
      trustConsentVersion?: number
    }
    remote.trustConsentVersion = 999
    mocks.httpGet
      .mockResolvedValueOnce({ body: JSON.stringify([remote]) })
      .mockResolvedValueOnce({ body: '[]' })

    const store = usePluginsStore()
    await store.updatePluginHub()

    expect((store.pluginHub[0] as any).trustConsentVersion).toBeUndefined()
    const saved = mocks.writeFile.mock.calls.find(([path]) => path === PluginHubFilePath)
    expect(saved).toBeTruthy()
    expect(saved![1]).not.toContain('trustConsentVersion')
  })
})

describe('usePluginsStore legacy plugins (installed before the consent mechanism)', () => {
  const LEGACY_CODE = 'async function onStartup() { globalThis.__legacyRan = true; return 0 }'

  const legacyRecord = (overrides: Partial<Plugin> = {}) =>
    // NOTE: deliberately NO trustConsentVersion field — this is the exact
    // on-disk shape written by app versions that predate the consent gate.
    makePlugin({
      id: 'user-legacy-1',
      type: 'File',
      url: '',
      path: 'data/plugins/legacy.js',
      triggers: [PluginTrigger.OnStartup],
      ...overrides,
    })

  const mockDisk = (record: Plugin) => {
    mocks.readFile.mockImplementation(async (path: string) => {
      if (path === PluginsFilePath) return stringify([record])
      if (path === record.path) return LEGACY_CODE
      throw 'not found'
    })
  }

  beforeEach(() => {
    setActivePinia(createPinia())
    mocks.confirm.mockReset()
    mocks.httpGet.mockReset()
    mocks.readFile.mockReset()
    mocks.writeFile.mockReset()
    mocks.writeFile.mockResolvedValue(undefined)
    ;(globalThis as any).__legacyRan = false
    Object.defineProperty(window, 'AsyncFunction', {
      configurable: true,
      writable: true,
      value: Object.getPrototypeOf(async function () {}).constructor,
    })
  })

  it('loads old data but keeps it unregistered when startup consent is dismissed', async () => {
    mockDisk(legacyRecord())
    mocks.confirm.mockRejectedValue('canceled')
    const store = usePluginsStore()

    await store.setupPlugins()

    expect(store.plugins).toHaveLength(1)
    expect((store.plugins[0] as any).trustConsentVersion).toBeUndefined()
    expect(mocks.confirm).toHaveBeenCalledTimes(1)
    expect(store.getPluginCodefromCache('user-legacy-1')).toBeUndefined()
  })

  it('asks for full-trust consent before trigger registration and then runs', async () => {
    mockDisk(legacyRecord())
    mocks.confirm.mockResolvedValue(true)
    const store = usePluginsStore()
    await store.setupPlugins()

    expect(mocks.confirm).toHaveBeenCalledWith(
      PLUGIN_FULL_TRUST_TITLE_KEY,
      PLUGIN_FULL_TRUST_WARNING_KEY,
      { type: 'text', okText: PLUGIN_FULL_TRUST_ACCEPT_KEY },
    )
    expect((globalThis as any).__legacyRan).toBe(false)
    // Consent is recorded and persisted...
    expect((store.plugins[0] as any).trustConsentVersion).toBe(PLUGIN_TRUST_CONSENT_VERSION)
    const saved = mocks.writeFile.mock.calls.find(([path]) => path === PluginsFilePath)
    expect(saved).toBeTruthy()
    expect(saved![1]).toContain(`trustConsentVersion: ${PLUGIN_TRUST_CONSENT_VERSION}`)
    // Registration happened only after durable consent; executions do not
    // prompt again.
    await store.onStartupTrigger()
    expect((globalThis as any).__legacyRan).toBe(true)
    await store.onStartupTrigger()
    expect(mocks.confirm).toHaveBeenCalledTimes(1)
  })

  it('a declined consent keeps the legacy plugin from executing', async () => {
    mockDisk(legacyRecord())
    mocks.confirm.mockRejectedValue('canceled')
    const store = usePluginsStore()
    await store.setupPlugins()

    await store.onStartupTrigger()

    expect((globalThis as any).__legacyRan).toBe(false)
    expect((store.plugins[0] as any).trustConsentVersion).toBeUndefined()
    // The decline is remembered for event-driven sweeps in this session.
    await store.onStartupTrigger()
    expect(mocks.confirm).toHaveBeenCalledTimes(1)
    expect((globalThis as any).__legacyRan).toBe(false)
  })

  it('a manual run re-offers the dialog after a decline and aborts if declined again', async () => {
    mockDisk(legacyRecord())
    mocks.confirm.mockRejectedValue('canceled')
    const store = usePluginsStore()
    await store.setupPlugins()
    await store.onStartupTrigger() // declined once (session memo)

    await expect(
      store.manualTrigger('user-legacy-1', PluginTriggerEvent.OnStartup),
    ).rejects.toBeTruthy()

    expect(mocks.confirm).toHaveBeenCalledTimes(2)
    expect((globalThis as any).__legacyRan).toBe(false)
  })

  it('an already-consented plugin loads and runs without any dialog', async () => {
    const record = legacyRecord()
    ;(record as any).trustConsentVersion = PLUGIN_TRUST_CONSENT_VERSION
    mockDisk(record)
    const store = usePluginsStore()
    await store.setupPlugins()

    await store.onStartupTrigger()

    expect(mocks.confirm).not.toHaveBeenCalled()
    expect((globalThis as any).__legacyRan).toBe(true)
  })

  it('times out one never-settling startup plugin and continues with the next plugin', async () => {
    vi.useFakeTimers()
    try {
      const hanging = legacyRecord({
        id: 'user-hanging-startup',
        name: 'Hanging startup plugin',
        path: 'data/plugins/hanging-startup.js',
      })
      const following = legacyRecord({
        id: 'user-following-startup',
        name: 'Following startup plugin',
        path: 'data/plugins/following-startup.js',
      })
      ;(hanging as any).trustConsentVersion = PLUGIN_TRUST_CONSENT_VERSION
      ;(following as any).trustConsentVersion = PLUGIN_TRUST_CONSENT_VERSION
      mocks.readFile.mockImplementation(async (path: string) => {
        if (path === PluginsFilePath) return stringify([hanging, following])
        if (path === hanging.path) {
          return 'async function onStartup() { await new Promise(() => undefined) }'
        }
        if (path === following.path) {
          return 'async function onStartup() { globalThis.__followingRan = true }'
        }
        throw 'not found'
      })
      ;(globalThis as any).__followingRan = false
      const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => undefined)

      const store = usePluginsStore()
      await store.setupPlugins()
      const startup = store.onStartupTrigger()
      await vi.advanceTimersByTimeAsync(STARTUP_PLUGIN_EXECUTION_TIMEOUT_MS)
      await startup

      expect((globalThis as any).__followingRan).toBe(true)
      expect(errorSpy).toHaveBeenCalledWith(
        expect.stringContaining('Hanging startup plugin timed out'),
      )
      errorSpy.mockRestore()
    } finally {
      vi.useRealTimers()
    }
  })
})
