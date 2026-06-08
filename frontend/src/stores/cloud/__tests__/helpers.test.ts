import { afterEach, describe, expect, it, vi } from 'vitest'

import {
  addUniquePort,
  cloudInstanceIdFromSubscriptionRef,
  hasUsableAddress,
  isManagedCloudOutboundId,
  isPublicIPv4Address,
  isReachableTargetStatus,
  joinRegexAlternatives,
  nodeSmartOutboundId,
  normalizeCloudNode,
  normalizeServerName,
  parseJSON,
  providerStatusToNodeStatus,
  resolveTLSInsecure,
  subscriptionId,
  subscriptionPath,
} from '../helpers'

describe('cloud helpers', () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('parses JSON with fallback on malformed provider data', () => {
    expect(parseJSON<{ ok: boolean }>('{"ok":true}', { ok: false })).toEqual({ ok: true })

    vi.spyOn(console, 'error').mockImplementation(() => {})
    expect(parseJSON('not-json', { ok: false })).toEqual({ ok: false })
    expect(parseJSON(null, { empty: true })).toEqual({ empty: true })
  })

  it('normalizes cloud subscription and smart outbound identifiers', () => {
    expect(subscriptionId('node-1')).toBe('cloud-node-1')
    expect(subscriptionId('cloud-node-1')).toBe('cloud-node-1')
    expect(subscriptionPath('node-1')).toBe('data/subscribes/cloud-node-1.json')
    expect(cloudInstanceIdFromSubscriptionRef('cloud-node-1')).toBe('node-1')
    expect(cloudInstanceIdFromSubscriptionRef('cloud-do-123')).toBe('cloud-do-123')
    expect(nodeSmartOutboundId('node-1')).toBe('outbound-smart-node-auto-cloud-node-1')
    expect(isManagedCloudOutboundId('outbound-smart-node-auto-cloud-node-1')).toBe(true)
    expect(isManagedCloudOutboundId('custom-outbound')).toBe(false)
  })

  it('builds regex alternatives and handles TLS helper defaults', () => {
    expect(joinRegexAlternatives(' hysteria ', undefined, 'vless')).toBe('(?:hysteria)|(?:vless)')
    expect(normalizeServerName(' edge.example.com ', 'fallback.example.com')).toBe(
      'edge.example.com',
    )
    expect(normalizeServerName('', 'fallback.example.com')).toBe('fallback.example.com')
    expect(resolveTLSInsecure({ hysteriaInsecure: true } as any, 'hysteria')).toBe(true)
    expect(resolveTLSInsecure({ trojanInsecure: false } as any, 'trojan')).toBe(false)
    expect(isReachableTargetStatus('open')).toBe(true)
    expect(isReachableTargetStatus('closed')).toBe(false)
  })

  it('deduplicates ports and rejects unusable addresses', () => {
    const ports: number[] = []
    addUniquePort(ports, 443)
    addUniquePort(ports, 443)
    addUniquePort(ports, 0)

    expect(ports).toEqual([443])
    expect(isPublicIPv4Address('203.0.113.10')).toBe(true)
    expect(isPublicIPv4Address('10.0.0.1')).toBe(false)
    expect(isPublicIPv4Address('100.64.0.1')).toBe(false)
    expect(hasUsableAddress({ instanceId: 'node-1', ipv4: '203.0.113.10' } as any)).toBe(true)
    expect(hasUsableAddress({ instanceId: 'node-1', ipv6: '::' } as any)).toBe(false)
    expect(hasUsableAddress({ ipv4: '203.0.113.10' } as any)).toBe(false)
  })

  it('normalizes provider node fields and maps provider statuses', () => {
    expect(normalizeCloudNode({
      ID: 'provider-id',
      Label: 'Provider Label',
      createdAt: 1_700_000_000_000,
    }, 'vultr')).toMatchObject({
      instanceId: 'provider-id',
      label: 'Provider Label',
      provider: 'vultr',
      createdAt: '2023-11-14T22:13:20.000Z',
    })

    expect(providerStatusToNodeStatus('running')).toBe('connected')
    expect(providerStatusToNodeStatus('provisioning')).toBe('pending')
    expect(providerStatusToNodeStatus('deploying')).toBe('applying')
    expect(providerStatusToNodeStatus('stopped')).toBe('error')
    expect(providerStatusToNodeStatus('unknown-status')).toBe('unknown')
  })
})
