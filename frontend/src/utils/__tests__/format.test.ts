import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import i18n from '@/lang'

import { formatBytes, formatDate, formatRelativeTime } from '../format'

describe('format utilities', () => {
  beforeEach(() => {
    i18n.global.locale.value = 'en'
    vi.spyOn(Date, 'now').mockReturnValue(new Date('2026-05-13T12:00:00Z').getTime())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('formats byte counts with units and invalid fallbacks', () => {
    expect(formatBytes(-1)).toBe('--')
    expect(formatBytes(Number.POSITIVE_INFINITY)).toBe('--')
    expect(formatBytes(0)).toBe('0 B')
    expect(formatBytes(1024)).toBe('1 KB')
    expect(formatBytes(1536, 2)).toBe('1.5 KB')
    expect(formatBytes(1024 ** 3 * 2.25)).toBe('2.3 GB')
  })

  it('formats relative time across common units', () => {
    expect(formatRelativeTime('not-a-date')).toBe('--')
    expect(formatRelativeTime(Date.now())).toBe('now')
    expect(formatRelativeTime(Date.now() - 60_000)).toBe('1 minute ago')
    expect(formatRelativeTime(Date.now() + 2 * 60 * 60 * 1000)).toBe('in 2 hours')
    expect(formatRelativeTime(Date.now() - 3 * 24 * 60 * 60 * 1000)).toBe('3 days ago')
  })

  it('formats dates with token replacement', () => {
    expect(formatDate('not-a-date', 'YYYY-MM-DD')).toBe('--')
    expect(formatDate('2026-05-13T09:08:07Z', 'YYYY/MM/DD HH:mm:ss')).toMatch(
      /^2026\/05\/13 \d{2}:08:07$/,
    )
  })
})
