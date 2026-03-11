import { beforeEach, describe, expect, it } from 'vitest'

import i18n from '@/lang'

import {
  BuiltinProfileIds,
  BuiltinRulesetIds,
  buildBuiltinProfiles,
  buildBuiltinRulesetSeeds,
} from '../builtinPresets'

describe('builtin presets', () => {
  beforeEach(() => {
    i18n.global.locale.value = 'en'
  })

  it('provides the expected ruleset catalogue', () => {
    const seeds = buildBuiltinRulesetSeeds()

    expect(seeds).toHaveLength(7)
    expect(new Set(seeds.map((seed) => seed.id)).size).toBe(seeds.length)
    expect(seeds.map((seed) => seed.id)).toEqual(
      expect.arrayContaining(Object.values(BuiltinRulesetIds)),
    )
    expect(seeds.every((seed) => seed.payload.rules.length > 0)).toBe(true)
  })

  it('builds complete profile presets with valid local ruleset references', () => {
    const profiles = buildBuiltinProfiles()

    expect(profiles.map((profile) => profile.id)).toEqual(
      expect.arrayContaining(Object.values(BuiltinProfileIds)),
    )

    for (const profile of profiles) {
      const localRulesetRefs = new Set(profile.route.rule_set.map((ruleset) => ruleset.id))
      const routeRules = profile.route.rules.filter((rule) => rule.type === 'rule_set')
      const dnsRules = profile.dns.rules.filter((rule) => rule.type === 'rule_set')

      expect(routeRules.length).toBeGreaterThan(0)
      expect(dnsRules.length).toBeGreaterThan(0)
      expect(routeRules.every((rule) => localRulesetRefs.has(rule.payload))).toBe(true)
      expect(dnsRules.every((rule) => localRulesetRefs.has(rule.payload))).toBe(true)
    }

    expect(
      profiles.find((profile) => profile.id === BuiltinProfileIds.Smart)?.experimental.clash_api
        .default_mode,
    ).toBe('rule')
    expect(
      profiles.find((profile) => profile.id === BuiltinProfileIds.Global)?.experimental.clash_api
        .default_mode,
    ).toBe('global')
    expect(
      profiles.find((profile) => profile.id === BuiltinProfileIds.Direct)?.experimental.clash_api
        .default_mode,
    ).toBe('direct')
  })
})
