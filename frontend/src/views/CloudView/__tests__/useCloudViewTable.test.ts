import { describe, expect, it } from 'vitest'

import { useCloudViewTable } from '../useCloudViewTable'

import type { ManagedCloudNode } from '@/stores/cloud'

const node = (overrides: Partial<ManagedCloudNode>): ManagedCloudNode => ({
  instanceId: 'node-1',
  label: 'Tokyo edge',
  region: 'nrt',
  ipv4: '203.0.113.10',
  connectivityStatus: 'reachable',
  statusText: 'connected',
  createdAt: '2026-01-01T00:00:00.000Z',
  ...overrides,
})

describe('useCloudViewTable', () => {
  it('derives table rows from filters and can clear active filters', () => {
    const cloudStore = {
      instances: [
        node({ instanceId: 'tokyo', label: 'Tokyo edge', region: 'nrt' }),
        node({
          instanceId: 'blocked',
          label: 'Frankfurt edge',
          region: 'fra',
          connectivityStatus: 'blocked',
          statusText: 'error',
        }),
      ],
    }
    const table = useCloudViewTable(cloudStore, (regionId) => ({
      nrt: 'Tokyo',
      fra: 'Frankfurt',
    })[regionId] ?? regionId)

    expect(table.columns.map((column) => column.key)).toEqual([
      'selection',
      'label',
      'region',
      'ipAddresses',
      'protocols',
      'status',
      'connectivity',
      'actions',
    ])
    expect(table.tableData.value.map((item) => item.id)).toEqual(['tokyo', 'blocked'])
    expect(table.hasActiveFilters.value).toBe(false)

    table.searchQuery.value = 'frankfurt'
    table.filterConnectivity.value = 'blocked'
    table.filterStatus.value = 'error'
    table.sortBy.value = 'label'
    table.sortOrder.value = 'desc'

    expect(table.hasActiveFilters.value).toBe(true)
    expect(table.tableData.value).toEqual([
      expect.objectContaining({ id: 'blocked', label: 'Frankfurt edge' }),
    ])

    table.clearFilters()

    expect(table.searchQuery.value).toBe('')
    expect(table.filterConnectivity.value).toBe('all')
    expect(table.filterStatus.value).toBe('all')
    expect(table.sortBy.value).toBe('')
    expect(table.sortOrder.value).toBe('asc')
    expect(table.hasActiveFilters.value).toBe(false)
  })
})
