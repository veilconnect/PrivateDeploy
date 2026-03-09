/**
 * Snapshot tests for smart routing configuration generation.
 *
 * These tests ensure that ensureSmartAutoRouting produces consistent output
 * before and after refactoring.
 */
import { describe, it, expect } from 'vitest'

// Import only pure functions - no Vue/Pinia dependencies
import { ensureSmartAutoRouting } from '../smartRouting'
import { deriveManagedExclude } from '../helpers'
import type { ProtocolHealthMap } from '../constants'

// ─── Minimal type stubs (avoid importing from Vue stores) ────────────────────

const makeOutbound = (overrides: Record<string, any> = {}) => ({
  id: '',
  tag: '',
  type: 'selector',
  outbounds: [] as any[],
  url: '',
  include: '',
  exclude: '',
  interval: '',
  tolerance: 0,
  interrupt_exist_connections: false,
  ...overrides,
})

const makeProfile = (overrides: Record<string, any> = {}) => ({
  id: 'test-profile',
  name: 'Test Profile',
  log: {},
  experimental: {},
  inbounds: [],
  outbounds: [
    makeOutbound({ id: 'outbound-select', tag: 'Proxy', type: 'selector' }),
    makeOutbound({ id: 'outbound-urlte', tag: 'Auto', type: 'urltest' }),
  ],
  route: {
    rules: [],
    rule_set: [],
    final: 'outbound-select',
    auto_detect_interface: false,
    default_interface: '',
    find_process: false,
  },
  dns: {},
  mixin: {},
  script: [],
  ...overrides,
}) as any

const cloudSub = (instanceId: string, label: string) => ({
  id: `cloud-${instanceId}`,
  type: 'Subscription',
  tag: label,
})

// ─── Tests ───────────────────────────────────────────────────────────────────

describe('ensureSmartAutoRouting', () => {
  it('no outbounds/rules when no cloud subscriptions', () => {
    const profile = makeProfile()
    ensureSmartAutoRouting(profile)

    const smart = profile.outbounds.filter((o: any) => o.id.startsWith('outbound-smart-'))
    expect(smart).toHaveLength(0)
  })

  it('correct outbound IDs for single node', () => {
    const profile = makeProfile()
    const sub = cloudSub('node-1', 'Tokyo')
    profile.outbounds[0].outbounds = [sub]
    profile.outbounds[1].outbounds = [sub]

    ensureSmartAutoRouting(profile)

    const ids = profile.outbounds
      .filter((o: any) => o.id.startsWith('outbound-smart-'))
      .map((o: any) => o.id)
      .sort()

    expect(ids).toMatchSnapshot()
  })

  it('correct rules for single node', () => {
    const profile = makeProfile()
    const sub = cloudSub('node-1', 'Tokyo')
    profile.outbounds[0].outbounds = [sub]
    profile.outbounds[1].outbounds = [sub]

    ensureSmartAutoRouting(profile)

    const rules = profile.route.rules
      .filter((r: any) => r.id.startsWith('rule-smart-'))
      .map((r: any) => ({ id: r.id, type: r.type, payload: r.payload, outbound: r.outbound }))

    expect(rules).toMatchSnapshot()
  })

  it('per-node outbounds for multiple nodes', () => {
    const profile = makeProfile()
    const subs = [
      cloudSub('node-1', 'Tokyo'),
      cloudSub('node-2', 'Frankfurt'),
      cloudSub('node-3', 'LA'),
    ]
    profile.outbounds[0].outbounds = [...subs]
    profile.outbounds[1].outbounds = [...subs]

    ensureSmartAutoRouting(profile)

    const perNode = profile.outbounds
      .filter((o: any) => o.id.startsWith('outbound-smart-node-'))
      .map((o: any) => ({ id: o.id, tag: o.tag, type: o.type }))

    expect(perNode).toHaveLength(3)
    expect(perNode).toMatchSnapshot()
  })

  it('applies protocol health exclusions', () => {
    const profile = makeProfile()
    const sub = cloudSub('node-1', 'Tokyo')
    profile.outbounds[0].outbounds = [sub]
    profile.outbounds[1].outbounds = [sub]

    const healthMap: ProtocolHealthMap = {
      'node-1': {
        hysteria2: {
          state: 'degraded',
          reason: 'connectivity-udp-unreachable',
          updatedAt: 1000,
        },
      },
    }

    ensureSmartAutoRouting(profile, healthMap)

    const nodeOut = profile.outbounds.find((o: any) => o.id.startsWith('outbound-smart-node-'))
    expect(nodeOut?.exclude).toBeTruthy()
    expect(nodeOut?.exclude).toMatchSnapshot()
  })

  it('sets route.final to smart auto', () => {
    const profile = makeProfile()
    const sub = cloudSub('node-1', 'Tokyo')
    profile.outbounds[0].outbounds = [sub]

    ensureSmartAutoRouting(profile)

    expect(profile.route.final).toBe('outbound-smart-auto')
  })

  it('is idempotent', () => {
    const profile = makeProfile()
    const sub = cloudSub('node-1', 'Tokyo')
    profile.outbounds[0].outbounds = [sub]
    profile.outbounds[1].outbounds = [sub]

    ensureSmartAutoRouting(profile)
    const first = JSON.stringify(profile)

    ensureSmartAutoRouting(profile)
    const second = JSON.stringify(profile)

    expect(first).toBe(second)
  })
})

describe('deriveManagedExclude', () => {
  it('empty for no entries', () => {
    expect(deriveManagedExclude(undefined)).toBe('')
    expect(deriveManagedExclude({})).toBe('')
  })

  it('empty for all healthy', () => {
    expect(
      deriveManagedExclude({
        shadowsocks: { state: 'healthy', reason: 'manual-override', updatedAt: 0 },
        hysteria2: { state: 'healthy', reason: 'manual-override', updatedAt: 0 },
      }),
    ).toBe('')
  })

  it('exclude pattern for degraded protocols', () => {
    const result = deriveManagedExclude({
      hysteria2: { state: 'degraded', reason: 'connectivity-udp-unreachable', updatedAt: 0 },
    })
    expect(result).toContain('hysteria')
    expect(result).toMatchSnapshot()
  })

  it('combines multiple degraded patterns', () => {
    const result = deriveManagedExclude({
      hysteria2: { state: 'degraded', reason: 'connectivity-udp-unreachable', updatedAt: 0 },
      vless: { state: 'degraded', reason: 'connectivity-tcp-unreachable', updatedAt: 0 },
    })
    expect(result).toContain('hysteria')
    expect(result).toContain('vless')
    expect(result).toMatchSnapshot()
  })
})
