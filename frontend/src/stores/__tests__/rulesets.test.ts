import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { stringify } from 'yaml'

import { RulesetFormat } from '@/enums/kernel'

const mocks = vi.hoisted(() => ({
  copyFile: vi.fn(),
  download: vi.fn(),
  fileExists: vi.fn(),
  httpGet: vi.fn(),
  readFile: vi.fn(),
  writeFile: vi.fn(),
}))

vi.mock('@/bridge', () => ({
  CopyFile: mocks.copyFile,
  Download: mocks.download,
  FileExists: mocks.fileExists,
  HttpGet: mocks.httpGet,
  ReadFile: mocks.readFile,
  WriteFile: mocks.writeFile,
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
  isValidRulesJson: (body: string) => {
    try {
      const parsed = JSON.parse(body)
      return Array.isArray(parsed.rules)
    } catch {
      return false
    }
  },
  omitArray: (list: Record<string, unknown>[], keys: string[]) =>
    list.map((item) => Object.fromEntries(Object.entries(item).filter(([key]) => !keys.includes(key)))),
}))

import { useRulesetsStore, type RuleSet } from '../rulesets'

const ruleset = (overrides: Partial<RuleSet> = {}): RuleSet => ({
  count: 0,
  disabled: false,
  format: RulesetFormat.Source,
  id: 'ruleset-1',
  path: 'data/rulesets/ruleset-1.json',
  tag: 'Ruleset 1',
  type: 'Http',
  updateTime: 0,
  url: 'https://rules.test/list.json',
  ...overrides,
})

describe('rulesets store', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    setActivePinia(createPinia())

    mocks.copyFile.mockResolvedValue(undefined)
    mocks.download.mockResolvedValue(undefined)
    mocks.fileExists.mockResolvedValue(false)
    mocks.httpGet.mockResolvedValue({
      body: {
        rules: [
          { domain: ['a.example', 'b.example'], ip_cidr: ['192.0.2.0/24'] },
          { port: 53 },
        ],
      },
    })
    mocks.readFile.mockRejectedValue(new Error('missing'))
    mocks.writeFile.mockResolvedValue(undefined)
  })

  it('loads rulesets and hub metadata from disk', async () => {
    const stored = [ruleset({ count: 2 })]
    const hub = { geoip: 'geoip.db', geosite: 'geosite.db', list: [{ count: 1, description: 'CN', name: 'cn', type: 'geosite' }] }
    mocks.readFile
      .mockResolvedValueOnce(stringify(stored))
      .mockResolvedValueOnce(JSON.stringify(hub))

    const store = useRulesetsStore()
    await store.setupRulesets()

    expect(store.rulesets).toEqual(stored)
    expect(store.rulesetHub).toEqual(hub)
  })

  it('adds, edits, deletes, and rolls back failed writes', async () => {
    const store = useRulesetsStore()
    const first = ruleset()
    await store.addRuleset(first)

    expect(store.getRulesetById('ruleset-1')).toEqual(first)
    expect(mocks.writeFile).toHaveBeenCalledWith(expect.stringContaining('rulesets'), expect.any(String))

    await store.editRuleset('ruleset-1', ruleset({ tag: 'Edited' }))
    expect(store.getRulesetById('ruleset-1')?.tag).toBe('Edited')

    await store.deleteRuleset('ruleset-1')
    expect(store.rulesets).toEqual([])

    await store.addRuleset(first)
    mocks.writeFile.mockRejectedValueOnce(new Error('disk full'))
    await expect(store.deleteRuleset('ruleset-1')).rejects.toThrow('disk full')
    expect(store.getRulesetById('ruleset-1')).toEqual(first)
  })

  it('updates source and binary rulesets and skips disabled entries in bulk updates', async () => {
    vi.spyOn(Date, 'now').mockReturnValue(10)
    const store = useRulesetsStore()
    const http = ruleset()
    const binary = ruleset({
      format: RulesetFormat.Binary,
      id: 'binary',
      path: 'data/rulesets/binary.srs',
      tag: 'Binary',
      type: 'Http',
      url: 'https://rules.test/binary.srs',
    })
    const disabled = ruleset({ disabled: true, id: 'disabled', tag: 'Disabled' })

    store.rulesets.push(http, binary, disabled)

    await expect(store.updateRuleset('ruleset-1')).resolves.toBe(
      'Ruleset [Ruleset 1] updated successfully.',
    )

    expect(http.count).toBe(4)
    expect(http.updateTime).toBe(10)
    expect(mocks.writeFile).toHaveBeenCalledWith(
      'data/rulesets/ruleset-1.json',
      JSON.stringify({
        rules: [
          { domain: ['a.example', 'b.example'], ip_cidr: ['192.0.2.0/24'] },
          { port: 53 },
        ],
      }, null, 2),
    )

    await expect(store.updateRuleset('missing')).rejects.toBe('missing Not Found')
    await expect(store.updateRuleset('disabled')).rejects.toBe('Disabled Disabled')

    await store.updateRulesets()

    expect(mocks.download).toHaveBeenCalledWith('https://rules.test/binary.srs', 'data/rulesets/binary.srs')
    expect(disabled.updating).toBeUndefined()
  })

  it('updates ruleset hub cache and exposes loading state', async () => {
    const hub = { geoip: 'geoip.db', geosite: 'geosite.db', list: [] }
    mocks.httpGet.mockResolvedValueOnce({ body: JSON.stringify(hub) })
    const store = useRulesetsStore()

    await store.updateRulesetHub()

    expect(store.rulesetHubLoading).toBe(false)
    expect(store.rulesetHub).toEqual(hub)
    expect(mocks.writeFile).toHaveBeenCalledWith('data/.cache/ruleset-list.json', JSON.stringify(hub))
  })
})
