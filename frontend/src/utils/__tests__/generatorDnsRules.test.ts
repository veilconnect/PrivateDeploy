import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it } from 'vitest'

import { RuleAction } from '@/enums/kernel'
import i18n from '@/lang'

import { buildBuiltinProfiles } from '../builtinPresets'
import { generateConfig } from '../generator'

describe('generator dns rules', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    i18n.global.locale.value = 'en'
    window.AsyncFunction = Object.getPrototypeOf(async function () {}).constructor as typeof window.AsyncFunction
  })

  it('emits explicit action fields for dns reject rules', async () => {
    const profile = buildBuiltinProfiles()[0]
    const config = await generateConfig(profile)
    const rejectRule = config.dns.rules.find((rule: Record<string, unknown>) => rule.method === 'default')

    expect(rejectRule).toBeTruthy()
    expect(rejectRule.action).toBe(RuleAction.Reject)
  })
})
