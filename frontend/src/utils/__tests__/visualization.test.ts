import { afterEach, describe, expect, it, vi } from 'vitest'

import {
  calculateUptime,
  formatLatency,
  generateConnectivityTimelinePath,
  generateLatencyLinePath,
  generateMockConnectivityHistory,
  getConnectivityStatusColor,
  getLatencyColor,
} from '../visualization'

describe('visualization utilities', () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('generates connectivity timeline coordinates and status colors', () => {
    expect(generateConnectivityTimelinePath([], 100, 20)).toBe('')
    expect(generateConnectivityTimelinePath([
      { timestamp: 1, status: 'reachable' },
      { timestamp: 2, status: 'icmp_blocked' },
      { timestamp: 3, status: 'blocked' },
    ], 100, 20)).toBe('0,10 50,10 100,10')

    expect(getConnectivityStatusColor('reachable')).toBe('#52c41a')
    expect(getConnectivityStatusColor('icmp_blocked')).toBe('#13c2c2')
    expect(getConnectivityStatusColor('blocked')).toBe('#ff4d4f')
    expect(getConnectivityStatusColor('testing')).toBe('#d9d9d9')
    expect(getConnectivityStatusColor('unknown')).toBe('#d9d9d9')
    expect(getConnectivityStatusColor('unexpected')).toBe('#d9d9d9')
  })

  it('generates latency line paths and display colors', () => {
    expect(generateLatencyLinePath([], 100, 40)).toBe('')
    expect(generateLatencyLinePath([
      { timestamp: 1, latency: 0 },
      { timestamp: 2, latency: 50 },
      { timestamp: 3, latency: 100 },
    ], 100, 40)).toBe('M 0,40 L 50,20 L 100,0')

    expect(getLatencyColor(99)).toBe('#52c41a')
    expect(getLatencyColor(100)).toBe('#faad14')
    expect(getLatencyColor(199)).toBe('#faad14')
    expect(getLatencyColor(200)).toBe('#ff7a45')
    expect(getLatencyColor(499)).toBe('#ff7a45')
    expect(getLatencyColor(500)).toBe('#ff4d4f')
  })

  it('formats latency and calculates uptime', () => {
    expect(formatLatency(42.4)).toBe('42ms')
    expect(formatLatency(999.5)).toBe('1000ms')
    expect(formatLatency(1_250)).toBe('1.25s')

    expect(calculateUptime([])).toBe(0)
    expect(calculateUptime([
      { timestamp: 1, status: 'reachable' },
      { timestamp: 2, status: 'icmp_blocked' },
      { timestamp: 3, status: 'blocked' },
      { timestamp: 4, status: 'unknown' },
    ])).toBe(50)
  })

  it('generates stable mock connectivity history', () => {
    vi.spyOn(Date, 'now').mockReturnValue(1_700_000_000_000)

    const history = generateMockConnectivityHistory('reachable', 24)

    expect(history).toHaveLength(48)
    expect(history[0]).toEqual({
      timestamp: 1_699_913_600_000,
      status: 'reachable',
    })
    expect(history[47]).toEqual({
      timestamp: 1_699_998_200_000,
      status: 'reachable',
    })
  })
})
