import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { Outbound } from '@/enums/kernel'
import i18n from '@/lang'

import { buildBuiltinProfiles } from '../builtinPresets'
import { generateConfig } from '../generator'

describe('generator proxy-group collapse', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    i18n.global.locale.value = 'en'
    window.AsyncFunction = Object.getPrototypeOf(async function () {})
      .constructor as typeof window.AsyncFunction
  })

  it('warns loudly and falls back to Direct when a configured proxy group resolves to zero nodes', async () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    const profile = buildBuiltinProfiles()[0]
    // A group configured to proxy through a subscription that is not present in
    // the store: generateOutbounds must NOT silently pretend it works.
    profile.outbounds.push({
      id: 'selector-under-test',
      tag: 'Collapse Test',
      type: Outbound.Selector,
      outbounds: [{ id: 'cloud-missing-subscription', tag: 'Ghost', type: 'Subscription' }],
    } as IOutbound)

    const config = await generateConfig(profile)

    const group = config.outbounds.find((o: Recordable) => o.tag === 'Collapse Test')
    expect(group).toBeTruthy()
    // Kept valid (sing-box needs >=1 member) by pointing at a Direct outbound...
    expect(group.outbounds).toHaveLength(1)
    const directTag = config.outbounds.find((o: Recordable) => o.type === Outbound.Direct)?.tag
    expect(group.outbounds[0]).toBe(directTag)
    // ...but the degradation is surfaced, not silent.
    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('was not found in the subscription store'),
    )
    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining('will go DIRECT'))

    warnSpy.mockRestore()
    errorSpy.mockRestore()
  })
})
