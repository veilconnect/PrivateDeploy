import { describe, expect, it } from 'vitest'

import { DnsServer, RuleAction, RuleType, Strategy } from '@/enums/kernel'

import { transformProfileV194 } from '../profilesUpgrader'

describe('profiles upgrader', () => {
  it('upgrades legacy DNS servers and rules for v1.9.4 profiles', () => {
    const config = {
      route: {},
      dns: {
        fakeip: {
          inet4_range: '198.18.0.0/15',
          inet6_range: 'fc00::/18',
        },
        servers: [
          { id: 'local', tag: 'local', address: 'local', address_resolver: '', detour: '' },
          { id: 'tcp', tag: 'tcp', address: 'tcp://1.1.1.1:53', address_resolver: 'resolver', detour: 'direct' },
          { id: 'tls', tag: 'tls', address: 'tls://dns.example.com:853', address_resolver: '', detour: '' },
          { id: 'quic', tag: 'quic', address: 'quic://dns.example.com:784', address_resolver: '', detour: '' },
          { id: 'https', tag: 'https', address: 'https://dns.example.com/dns-query', address_resolver: '', detour: '' },
          { id: 'h3', tag: 'h3', address: 'h3://dns.example.com:443/dns-query', address_resolver: '', detour: '' },
          { id: 'dhcp', tag: 'dhcp', address: 'dhcp://eth0', address_resolver: '', detour: '' },
          { id: 'fakeip', tag: 'fakeip', address: 'fakeip', address_resolver: '', detour: '' },
          { id: 'rcode', tag: 'rcode', address: 'rcode://success', address_resolver: '', detour: '' },
          { id: 'udp', tag: 'udp', address: '8.8.8.8', address_resolver: '', detour: '' },
        ],
        rules: [
          { id: 'outbound', type: 'outbound', server: 'remote-dns' },
          {
            id: 'rule-1',
            type: RuleType.DomainSuffix,
            payload: ['example.com'],
            action: RuleAction.Route,
            invert: true,
            server: 'local',
          },
        ],
      },
    }

    const profile = transformProfileV194(config as any) as any

    expect(profile.route.default_domain_resolver).toEqual({
      server: 'remote-dns',
      client_subnet: '',
    })
    expect(profile.dns.servers.map((server: any) => [server.id, server.type])).toEqual([
      ['local', DnsServer.Local],
      ['tcp', DnsServer.Tcp],
      ['tls', DnsServer.Tls],
      ['quic', DnsServer.Quic],
      ['https', DnsServer.Https],
      ['h3', DnsServer.H3],
      ['dhcp', DnsServer.Dhcp],
      ['fakeip', DnsServer.FakeIP],
      ['udp', DnsServer.Udp],
    ])
    expect(profile.dns.servers.find((server: any) => server.id === 'tcp')).toMatchObject({
      server: '1.1.1.1',
      server_port: '53',
      domain_resolver: 'resolver',
      detour: 'direct',
    })
    expect(profile.dns.servers.find((server: any) => server.id === 'https')).toMatchObject({
      server: 'dns.example.com',
      path: '/dns-query',
    })
    expect(profile.dns.servers.find((server: any) => server.id === 'dhcp')).toMatchObject({
      interface: 'eth0',
    })
    expect(profile.dns.servers.find((server: any) => server.id === 'fakeip')).toMatchObject({
      inet4_range: '198.18.0.0/15',
      inet6_range: 'fc00::/18',
    })
    expect(profile.dns.rules).toEqual([
      {
        id: 'rule-1',
        type: RuleType.DomainSuffix,
        payload: ['example.com'],
        action: RuleAction.Route,
        invert: true,
        server: 'local',
        strategy: Strategy.Default,
        disable_cache: false,
        client_subnet: '',
      },
    ])
    expect(profile.dns.fakeip).toBeUndefined()
  })
})
