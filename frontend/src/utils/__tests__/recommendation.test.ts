import { afterEach, describe, expect, it, vi } from 'vitest'

import {
  calculateNodeScore,
  getBestNode,
  getRecommendedNodes,
  getRecommendedRegion,
} from '../recommendation'

import type { ManagedCloudNode } from '@/stores/cloud'

const node = (overrides: Partial<ManagedCloudNode> = {}): ManagedCloudNode => ({
  instanceId: 'node-1',
  label: 'Tokyo edge',
  region: 'nrt',
  connectivityStatus: 'reachable',
  ssPort: 8388,
  ssPassword: 'secret',
  createdAt: '2026-01-10T00:00:00.000Z',
  ...overrides,
})

describe('recommendation utilities', () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('scores nodes using latency, reachability, connectivity, and recency signals', () => {
    vi.spyOn(Date, 'now').mockReturnValue(new Date('2026-01-20T00:00:00.000Z').getTime())

    const score = calculateNodeScore(node({
      hysteriaPort: 443,
      hysteriaPassword: 'hy',
      vlessPort: 8443,
      vlessUUID: 'uuid',
      vlessPublicKey: 'pk',
      vlessShortId: 'sid',
    }), {
      preferLowLatency: true,
      preferLowRisk: true,
      preferReachable: true,
      preferRecent: true,
    }, new Map([['nrt', 42]]))

    expect(score.score).toBeGreaterThan(80)
    expect(score.antiBlockingScore).toBeGreaterThan(80)
    expect(score.reasons).toEqual(expect.arrayContaining([
      'Excellent latency (<50ms)',
      'Protocol diversity is strong',
      'Hysteria2 (UDP/QUIC) available',
      'Currently reachable',
    ]))
  })

  it('penalizes blocked nodes and records the avoid-blocked reason', () => {
    const blocked = calculateNodeScore(node({
      region: 'ewr',
      connectivityStatus: 'blocked',
      createdAt: '2025-01-01T00:00:00.000Z',
    }), {
      avoidBlocked: true,
      preferReachable: true,
    }, new Map([['ewr', 500]]))

    expect(blocked.score).toBeLessThan(30)
    expect(blocked.reasons).toEqual(expect.arrayContaining([
      'Currently blocked',
      'Blocked nodes avoided',
      'Node is relatively old',
    ]))
  })

  it('sorts recommendations and returns the best node', () => {
    vi.spyOn(Date, 'now').mockReturnValue(new Date('2026-01-20T00:00:00.000Z').getTime())

    const fast = node({ instanceId: 'fast', region: 'nrt', connectivityStatus: 'reachable' })
    const medium = node({ instanceId: 'medium', region: 'fra', connectivityStatus: 'icmp_blocked' })
    const blocked = node({ instanceId: 'blocked', region: 'ewr', connectivityStatus: 'blocked' })
    const latencyMap = new Map([
      ['nrt', 40],
      ['fra', 120],
      ['ewr', 20],
    ])

    expect(getRecommendedNodes([blocked, medium, fast], {
      preferLowRisk: true,
      avoidBlocked: true,
    }, latencyMap).map((result) => result.node.instanceId)).toEqual(['fast', 'medium', 'blocked'])
    expect(getBestNode([blocked, medium, fast], {}, latencyMap)?.node.instanceId).toBe('fast')
    expect(getBestNode([], {}, latencyMap)).toBeNull()
  })

  it('selects regions by risk and latency score', () => {
    expect(getRecommendedRegion(['ewr', 'nrt', 'fra'], new Map([
      ['ewr', 20],
      ['nrt', 80],
      ['fra', 40],
    ]))).toBe('nrt')
    expect(getRecommendedRegion([], new Map())).toBeNull()
  })
})
