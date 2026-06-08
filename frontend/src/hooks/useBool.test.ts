import { describe, expect, it } from 'vitest'

import { useBool } from './useBool'

describe('useBool', () => {
  it('returns a ref and toggles its boolean value', () => {
    const [enabled, toggle] = useBool(false)

    expect(enabled.value).toBe(false)

    toggle()
    expect(enabled.value).toBe(true)

    toggle()
    expect(enabled.value).toBe(false)
  })
})
