import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { stringify } from 'yaml'

import { RulesetType, RuleType } from '@/enums/kernel'

const mocks = vi.hoisted(() => ({
  alert: vi.fn(),
  moveFile: vi.fn(),
  readDir: vi.fn(),
  readFile: vi.fn(),
  transformProfileV189To190: vi.fn(),
  transformProfileV194: vi.fn(),
  writeFile: vi.fn(),
}))

vi.mock('@/bridge', () => ({
  MoveFile: mocks.moveFile,
  ReadDir: mocks.readDir,
  ReadFile: mocks.readFile,
  WriteFile: mocks.writeFile,
}))

vi.mock('@/utils', () => ({
  alert: mocks.alert,
  asyncPool: async () => undefined,
  debounce: (fn: (...args: unknown[]) => unknown) => fn,
  ignoredError: async (fn: (...args: unknown[]) => Promise<unknown>, ...args: unknown[]) => {
    try {
      return await fn(...args)
    } catch {
      return undefined
    }
  },
  isValidRulesJson: () => true,
  omitArray: (list: unknown) => list,
  transformProfileV189To190: (...args: unknown[]) => mocks.transformProfileV189To190(...args),
  transformProfileV194: (...args: unknown[]) => mocks.transformProfileV194(...args),
}))

import { useProfilesStore } from '../profiles'
import { useRulesetsStore } from '../rulesets'

const profile = (overrides: Record<string, unknown> = {}) => ({
  dns: {
    rules: [],
  },
  experimental: {
    clash_api: {
      external_controller: '127.0.0.1:20123',
      secret: '',
    },
  },
  id: 'profile-1',
  inbounds: [],
  mixin: '',
  name: 'Profile 1',
  outbounds: [],
  route: {
    default_interface: '',
    rule_set: [],
    rules: [],
  },
  script: '',
  ...overrides,
}) as unknown as IProfile

describe('profiles store', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    setActivePinia(createPinia())

    mocks.alert.mockResolvedValue(undefined)
    mocks.moveFile.mockResolvedValue(undefined)
    mocks.readDir.mockResolvedValue([])
    mocks.readFile.mockRejectedValue(new Error('missing'))
    mocks.transformProfileV189To190.mockImplementation((value) => profile({ ...value, route: { rule_set: [], rules: [] } }))
    mocks.transformProfileV194.mockImplementation((value) => ({
      ...value,
      dns: { ...value.dns, fakeip: undefined },
    }))
    mocks.writeFile.mockResolvedValue(undefined)
  })

  it('loads profiles and prunes invalid ruleset references during setup', async () => {
    useRulesetsStore().rulesets.push({
      count: 0,
      disabled: false,
      format: 'source',
      id: 'valid-ruleset',
      path: '',
      tag: 'Valid ruleset',
      type: 'Manual',
      updateTime: 0,
      url: '',
    } as any)

    const storedProfile = profile({
      dns: {
        rules: [
          {
            id: 'dns-rule',
            invert: undefined,
            payload: 'valid-local,missing-local',
            type: RuleType.RuleSet,
          },
        ],
      },
      inbounds: [
        {
          enable: true,
          id: 'tun',
          tag: 'tun',
          tun: {},
          type: 'tun',
        },
      ],
      route: {
        default_interface: '',
        rule_set: [
          { id: 'remote', path: 'remote-ruleset', type: RulesetType.Remote },
          { id: 'valid-local', path: 'valid-ruleset', type: RulesetType.Local },
          { id: 'missing-local', path: 'missing-ruleset', type: RulesetType.Local },
        ],
        rules: [
          {
            id: 'route-rule',
            payload: 'valid-local,missing-local',
            type: RuleType.RuleSet,
          },
        ],
      },
    })
    mocks.readFile.mockResolvedValueOnce(stringify([storedProfile]))

    const store = useProfilesStore()
    await store.setupProfiles()

    expect(store.profiles[0].route.rule_set.map((item: any) => item.id)).toEqual(['valid-local'])
    expect(store.profiles[0].route.rules).toEqual([
      expect.objectContaining({ payload: 'valid-local' }),
    ])
    expect(store.profiles[0].dns.rules).toEqual([
      expect.objectContaining({ invert: false, payload: 'valid-local' }),
    ])
    expect((store.profiles[0].inbounds[0] as any).tun.route_exclude_address).toEqual([])
    expect(mocks.writeFile).toHaveBeenCalledWith('data/profiles.yaml', expect.any(String))
  })

  it('imports backup profiles once and alerts after legacy upgrades', async () => {
    const legacy = { id: 'legacy', name: 'Legacy' }
    mocks.readFile
      .mockResolvedValueOnce('')
      .mockResolvedValueOnce(stringify([legacy]))
    mocks.readDir.mockResolvedValueOnce([{ name: 'profiles-backup.yaml' }])

    const store = useProfilesStore()
    await store.setupProfiles()

    expect(mocks.transformProfileV189To190).toHaveBeenCalledWith(legacy)
    expect(mocks.moveFile).toHaveBeenCalledWith(
      'data/.cache/profiles-backup.yaml',
      'data/.cache/profiles-backup.yaml.done',
    )
    expect(mocks.alert).toHaveBeenCalledWith(
      'Tip',
      'The old profiles have been upgraded. Please adjust manually if necessary.',
    )
  })

  it('adds, edits, deletes, and rolls back failed writes', async () => {
    const store = useProfilesStore()
    const first = profile()

    await store.addProfile(first)
    expect(store.getProfileById('profile-1')).toEqual(first)

    await store.editProfile('profile-1', profile({ id: 'profile-1', name: 'Edited' }))
    expect(store.getProfileById('profile-1')?.name).toBe('Edited')

    await store.deleteProfile('missing')
    expect(store.profiles).toHaveLength(1)

    mocks.writeFile.mockRejectedValueOnce(new Error('disk full'))
    await expect(store.deleteProfile('profile-1')).rejects.toThrow('disk full')
    expect(store.getProfileById('profile-1')?.name).toBe('Edited')
  })
})
