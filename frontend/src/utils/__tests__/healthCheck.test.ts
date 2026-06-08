import { afterEach, describe, expect, it, vi } from 'vitest'

import {
  checkAllNodesHealth,
  checkNodeHealth,
  getHealthSummary,
  getRemediationActions,
  getUnhealthyNodes,
  scheduleHealthChecks,
} from '../healthCheck'

import type { ManagedCloudNode } from '@/stores/cloud'

vi.mock('../logger', () => ({
  logInfo: vi.fn(),
}))

const node = (overrides: Partial<ManagedCloudNode> = {}): ManagedCloudNode => ({
  instanceId: 'node-1',
  label: 'Tokyo edge',
  connectivityStatus: 'reachable',
  ipv4: '203.0.113.10',
  ssPort: 8388,
  ssPassword: 'secret',
  ...overrides,
})

describe('health check utilities', () => {
  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it('marks configured reachable nodes as healthy', () => {
    vi.spyOn(Date, 'now').mockReturnValue(new Date('2026-02-01T00:00:00.000Z').getTime())

    expect(checkNodeHealth(node({ createdAt: '2026-01-01T00:00:00.000Z' }), {
      connectivity: 'good',
      latency: 80,
      uptime: 99.9,
    })).toEqual({
      nodeId: 'node-1',
      healthy: true,
      score: 100,
      issues: [],
      recommendations: [],
      lastCheck: new Date('2026-02-01T00:00:00.000Z').getTime(),
    })
  })

  it('deducts score for blocked, stale, unconfigured, and unstable nodes', () => {
    vi.spyOn(Date, 'now').mockReturnValue(new Date('2026-05-01T00:00:00.000Z').getTime())

    const result = checkNodeHealth(node({
      connectivityStatus: 'blocked',
      ipv4: undefined,
      ssPort: undefined,
      ssPassword: undefined,
      createdAt: '2026-01-01T00:00:00.000Z',
    }), {
      connectivity: 'poor',
      latency: 750,
      uptime: 90,
    })

    expect(result).toMatchObject({
      nodeId: 'node-1',
      healthy: false,
      score: 0,
      issues: expect.arrayContaining([
        'Node is completely blocked',
        'High latency: 750ms',
        'No protocols configured',
        'No IP addresses available',
        'Node is 120 days old',
        'Low uptime: 90.0%',
      ]),
      recommendations: expect.arrayContaining([
        'Consider rotating IP or deploying to different region',
        'Consider deploying closer region',
        'Consider rotating IP periodically',
        'Check node stability',
      ]),
    })
  })

  it('summarizes health results and extracts remediation actions', () => {
    const healthy = checkNodeHealth(node({ instanceId: 'healthy' }))
    const unknown = checkNodeHealth(node({
      instanceId: 'unknown',
      connectivityStatus: 'unknown',
      trojanPort: 443,
      trojanPassword: 'secret',
    }))
    const blocked = checkNodeHealth(node({
      instanceId: 'blocked',
      connectivityStatus: 'blocked',
      ipv4: undefined,
      ssPort: undefined,
      ssPassword: undefined,
    }), { connectivity: 'poor', latency: 600, uptime: 99 })

    expect(checkAllNodesHealth([node({ instanceId: 'a' }), node({ instanceId: 'b' })])).toHaveLength(2)
    expect(getUnhealthyNodes([healthy, unknown, blocked])).toEqual([blocked])
    expect(getHealthSummary([healthy, unknown, blocked])).toEqual({
      total: 3,
      healthy: 2,
      unhealthy: 1,
      avgScore: 60,
      criticalIssues: 1,
    })
    expect(getHealthSummary([])).toEqual({
      total: 0,
      healthy: 0,
      unhealthy: 0,
      avgScore: 0,
      criticalIssues: 0,
    })
    expect(getRemediationActions(blocked)).toEqual([
      'Rotate IP address',
      'Deploy new node in different region',
      'Test connectivity to verify latency',
      'Consider deploying to closer region',
      'Configure at least one protocol',
    ])
    expect(getRemediationActions(unknown)).toEqual(['Run connectivity test'])
  })

  it('runs scheduled checks until cleanup is called', () => {
    vi.useFakeTimers()
    const checkFn = vi.fn()

    const cleanup = scheduleHealthChecks(checkFn, 1_000)
    vi.advanceTimersByTime(2_500)

    expect(checkFn).toHaveBeenCalledTimes(2)

    cleanup()
    vi.advanceTimersByTime(1_000)

    expect(checkFn).toHaveBeenCalledTimes(2)
  })
})
