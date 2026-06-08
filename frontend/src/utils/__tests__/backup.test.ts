import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import {
  autoBackup,
  clearAutoBackup,
  createBackup,
  getAutoBackupAge,
  isBackupCompatible,
  loadAutoBackup,
  parseBackup,
} from '../backup'

describe('backup utilities', () => {
  beforeEach(() => {
    localStorage.clear()
    vi.spyOn(Date, 'now').mockReturnValue(1_700_000_000_000)
    vi.spyOn(console, 'info').mockImplementation(() => {})
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('serializes backup data with stable version metadata', async () => {
    const serialized = await createBackup({
      cloudConfig: { provider: 'vultr' },
      nodes: [{ label: 'tokyo-edge' }],
    })

    expect(JSON.parse(serialized)).toEqual({
      version: '1.0.0',
      timestamp: 1_700_000_000_000,
      cloudConfig: { provider: 'vultr' },
      nodes: [{ label: 'tokyo-edge' }],
    })
  })

  it('validates backup structure and compatibility', () => {
    expect(parseBackup('{"version":"1.0.0","timestamp":1}')).toEqual({
      version: '1.0.0',
      timestamp: 1,
    })
    expect(isBackupCompatible({ version: '1.2.3', timestamp: 1 })).toBe(true)
    expect(isBackupCompatible({ version: '2.0.0', timestamp: 1 })).toBe(false)

    vi.spyOn(console, 'error').mockImplementation(() => {})
    expect(() => parseBackup('{"version":"1.0.0"}')).toThrow('Invalid backup file format')
    expect(() => parseBackup('not-json')).toThrow('Invalid backup file format')
  })

  it('saves, reads, ages, and clears auto-backups in localStorage', () => {
    autoBackup({ settings: { theme: 'dark' } })

    expect(loadAutoBackup()).toMatchObject({
      version: '1.0.0',
      timestamp: 1_700_000_000_000,
      settings: { theme: 'dark' },
    })

    vi.mocked(Date.now).mockReturnValue(1_700_000_005_000)
    expect(getAutoBackupAge()).toBe(5_000)

    clearAutoBackup()
    expect(loadAutoBackup()).toBeNull()
    expect(getAutoBackupAge()).toBeNull()
  })
})
