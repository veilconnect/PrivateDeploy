import { beforeEach, describe, expect, it } from 'vitest'

import { migrateSensitiveBrowserStorage } from '../sensitiveData'

describe('migrateSensitiveBrowserStorage', () => {
  beforeEach(() => localStorage.clear())

  it('proactively redacts every known legacy cache without waiting for a read', () => {
    localStorage.setItem('offline-cache-config', JSON.stringify({
      timestamp: 1,
      data: { provider: 'vultr', apiKey: 'legacy-provider-key' },
    }))
    localStorage.setItem('auto-backup', JSON.stringify({
      version: '1.0.0',
      timestamp: 1,
      nodes: [{ label: 'edge', ssPassword: 'legacy-node-secret' }],
    }))

    expect(migrateSensitiveBrowserStorage()).toEqual({ migrated: 2, removed: 0 })
    expect(localStorage.getItem('offline-cache-config')).not.toContain('legacy-provider-key')
    expect(localStorage.getItem('offline-cache-config')).toContain('vultr')
    expect(localStorage.getItem('auto-backup')).not.toContain('legacy-node-secret')
    expect(localStorage.getItem('auto-backup')).toContain('edge')
  })

  it('removes malformed known cache entries and leaves unrelated settings alone', () => {
    localStorage.setItem('offline-cache-nodes', 'not-json')
    localStorage.setItem('notificationSettings', '{"enabled":true}')

    expect(migrateSensitiveBrowserStorage()).toEqual({ migrated: 0, removed: 1 })
    expect(localStorage.getItem('offline-cache-nodes')).toBeNull()
    expect(localStorage.getItem('notificationSettings')).toBe('{"enabled":true}')
  })
})
