import { describe, expect, it } from 'vitest'

import {
  buildNodeProtocolLinks,
  getDeploymentSteps,
  getDeploymentSummary,
  hasCdnRelay,
  hasHysteria,
  hasShadowsocks,
  hasTrojan,
  hasVless,
  isPublicIPv4,
  shouldShowDeploymentProgress,
} from '../cloudNodeDisplay'

import type { CloudNode } from '@/types/cloud'

type DisplayNode = CloudNode & { statusText?: string }

const translate = (key: string, params?: Record<string, unknown>) => (
  params ? `${key}:${JSON.stringify(params)}` : key
)

const node = (overrides: Partial<DisplayNode> = {}): DisplayNode => ({
  instanceId: 'node-1',
  label: 'Edge 1',
  status: 'running',
  statusText: 'pending',
  ipv4: '203.0.113.10',
  ssPort: 8388,
  ssPassword: 'ss-secret',
  hysteriaPort: 443,
  hysteriaPassword: 'hy-secret',
  vlessPort: 8443,
  vlessUUID: '11111111-1111-4111-8111-111111111111',
  vlessPublicKey: 'public-key',
  vlessShortId: 'short-id',
  trojanPort: 9443,
  trojanPassword: 'trojan-secret',
  vlessRelayPort: 10000,
  ...overrides,
})

describe('cloud node display helpers', () => {
  it('detects public addresses and configured protocols', () => {
    expect(isPublicIPv4('203.0.113.10')).toBe(true)
    expect(isPublicIPv4('10.0.0.1')).toBe(false)
    expect(isPublicIPv4('172.16.0.1')).toBe(false)
    expect(isPublicIPv4('192.168.1.1')).toBe(false)
    expect(isPublicIPv4('100.64.0.1')).toBe(false)
    expect(isPublicIPv4('not-an-ip')).toBe(false)

    expect(hasShadowsocks(node())).toBe(true)
    expect(hasShadowsocks({ port: 8388, password: 'legacy' })).toBe(true)
    expect(hasHysteria(node())).toBe(true)
    expect(hasVless(node())).toBe(true)
    expect(hasTrojan(node())).toBe(true)
    expect(hasCdnRelay(node())).toBe(true)
    expect(hasVless({ vlessPort: 8443, vlessUUID: 'uuid' })).toBe(false)
  })

  it('builds protocol links and prefers active custom CDN hosts', () => {
    const links = buildNodeProtocolLinks(node({
      hysteriaInsecure: true,
      trojanInsecure: true,
    }), {
      nodeId: 'node-1',
      scriptName: 'relay',
      workerHost: 'relay.worker.dev',
      backend: '203.0.113.10:10000',
      deployedAt: '2026-01-01T00:00:00.000Z',
      customHost: 'relay.example.com',
      customHostStatus: 'active',
    })

    expect(links.map((link) => link.label)).toEqual([
      'Shadowsocks',
      'Hysteria2',
      'VLESS-Reality',
      'Trojan',
      'VLESS-CDN',
    ])
    expect(links.find((link) => link.label === 'Hysteria2')?.url).toContain('insecure=1')
    expect(links.find((link) => link.label === 'Trojan')?.url).toContain('allowInsecure=1')
    expect(links.find((link) => link.label === 'VLESS-CDN')?.url).toContain('relay.example.com:443')

    const fallback = buildNodeProtocolLinks(node(), {
      nodeId: 'node-1',
      scriptName: 'relay',
      workerHost: 'relay.worker.dev',
      backend: '203.0.113.10:10000',
      deployedAt: '2026-01-01T00:00:00.000Z',
      customHost: 'relay.example.com',
      customHostStatus: 'pending',
    })
    expect(fallback.find((link) => link.label === 'VLESS-CDN')?.url).toContain('relay.worker.dev:443')
  })

  it('omits links without a usable host or required protocol fields', () => {
    expect(buildNodeProtocolLinks(node({
      ipv4: '10.0.0.1',
      ipv6: '',
      ssPort: undefined,
      hysteriaPort: undefined,
      vlessPort: undefined,
      trojanPort: undefined,
      vlessRelayPort: undefined,
    }))).toEqual([])

    expect(buildNodeProtocolLinks(node({
      ipv4: '10.0.0.1',
      ipv6: '2001:db8::1',
      hysteriaPort: undefined,
      vlessPort: undefined,
      trojanPort: undefined,
      vlessRelayPort: undefined,
    }))[0].url).toContain('#Edge%201')
  })

  it('computes deployment step state and summaries', () => {
    expect(shouldShowDeploymentProgress(node({ statusText: 'pending' }))).toBe(true)
    expect(shouldShowDeploymentProgress(node({ statusText: 'connected' }))).toBe(false)
    expect(shouldShowDeploymentProgress(node({ statusText: 'error' }))).toBe(false)

    expect(getDeploymentSteps(node({ statusText: 'pending' }), translate)).toEqual([
      { label: 'cloud.progress.submitted', state: 'done' },
      { label: 'cloud.progress.provisioning', state: 'done' },
      { label: 'cloud.progress.waitingIp', state: 'done' },
      { label: 'cloud.progress.configuring', state: 'done' },
      { label: 'cloud.progress.ready', state: 'current' },
    ])

    expect(getDeploymentSteps(node({
      status: 'creating',
      ipv4: '',
      ssPort: undefined,
      hysteriaPort: undefined,
      vlessPort: undefined,
      trojanPort: undefined,
    }), translate).map((step) => step.state)).toEqual(['done', 'current', 'pending', 'pending', 'pending'])

    expect(getDeploymentSummary(node({ statusText: 'connected' }), translate)).toBe(
      'cloud.progress.summary:{"current":5,"total":5,"label":"cloud.progress.ready"}',
    )
  })
})
