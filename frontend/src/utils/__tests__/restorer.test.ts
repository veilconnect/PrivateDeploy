import { describe, expect, it, vi } from 'vitest'

const idMock = vi.hoisted(() => ({
  count: 0,
  next: () => `id-${++idMock.count}`,
}))

vi.mock('../others', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../others')>()

  return {
    ...actual,
    deepAssign: (target: Record<string, any>, source: Record<string, any>) => {
      Object.entries(source).forEach(([key, value]) => {
        if (
          value &&
          typeof value === 'object' &&
          !Array.isArray(value) &&
          target[key] &&
          typeof target[key] === 'object'
        ) {
          Object.assign(target[key], value)
        } else {
          target[key] = value
        }
      })
      return target
    },
    sampleID: idMock.next,
  }
})

import { Inbound, Outbound, RuleAction, Strategy, TunStack } from '@/enums/kernel'

import { restoreProfile } from '../restorer'

describe('restoreProfile', () => {
  it('converts supported sing-box fields into editable profile records', () => {
    idMock.count = 0

    const profile = restoreProfile({
      log: {
        level: 'debug',
        timestamp: true,
      },
      experimental: {
        clash_api: {
          external_controller: '127.0.0.1:9090',
        },
      },
      inbounds: [
        {
          tag: 'mixed-in',
          type: Inbound.Mixed,
          listen: '0.0.0.0',
          listen_port: 20122,
          tcp_fast_open: true,
          tcp_multi_path: false,
          udp_fragment: true,
          users: [{ username: 'alice', password: 'secret' }],
        },
        {
          tag: 'tun-in',
          type: Inbound.Tun,
          mtu: 1500,
          auto_route: true,
          strict_route: true,
          endpoint_independent_nat: true,
          stack: TunStack.System,
        },
        {
          tag: 'unsupported-in',
          type: 'shadowtls',
        },
      ],
      outbounds: [
        {
          tag: 'select',
          type: Outbound.Selector,
          outbounds: ['direct', 'missing'],
        },
        {
          tag: 'direct',
          type: Outbound.Direct,
        },
        {
          tag: 'unsupported-out',
          type: 'vmess',
        },
      ],
      route: {
        rule_set: [],
        rules: [],
      },
      dns: {
        disable_cache: true,
        disable_expire: true,
        independent_cache: true,
        final: 'remote',
        strategy: Strategy.PreferIPv4,
        client_subnet: '1.2.3.0/24',
        servers: [
          { tag: 'local' },
          { tag: 'remote' },
        ],
        rules: [
          { action: RuleAction.Reject, server: 'local' },
          { server: 'missing' },
        ],
      },
    }) as any

    expect(profile.id).toBe('id-1')
    expect(profile.name).toBe('id-2')
    expect(profile.log).toMatchObject({
      level: 'debug',
      timestamp: true,
    })
    expect(profile.experimental.clash_api.external_controller).toBe('127.0.0.1:9090')

    expect(profile.inbounds).toHaveLength(2)
    expect(profile.inbounds[0]).toEqual(expect.objectContaining({
      id: 'id-3',
      tag: 'mixed-in',
      type: Inbound.Mixed,
      enable: true,
      mixed: {
        listen: {
          listen: '0.0.0.0',
          listen_port: 20122,
          tcp_fast_open: true,
          tcp_multi_path: false,
          udp_fragment: true,
        },
        users: ['alice:secret'],
      },
    }))
    expect(profile.inbounds[1]).toEqual(expect.objectContaining({
      id: 'id-4',
      tag: 'tun-in',
      type: Inbound.Tun,
      tun: expect.objectContaining({
        address: ['172.18.0.1/30', 'fdfe:dcba:9876::1/126'],
        auto_route: true,
        endpoint_independent_nat: true,
        mtu: 1500,
        stack: TunStack.System,
        strict_route: true,
      }),
    }))

    expect(profile.outbounds).toHaveLength(2)
    expect(profile.outbounds[0]).toEqual(expect.objectContaining({
      id: 'id-6',
      tag: 'select',
      outbounds: [
        {
          id: 'id-7',
          tag: 'direct',
          type: 'Built-in',
        },
      ],
    }))
    expect(profile.outbounds[1]).toEqual(expect.objectContaining({
      id: 'id-7',
      tag: 'direct',
    }))

    expect(profile.dns).toEqual(expect.objectContaining({
      client_subnet: '1.2.3.0/24',
      disable_cache: true,
      disable_expire: true,
      final: 'id-10',
      independent_cache: true,
      strategy: Strategy.PreferIPv4,
      servers: [{}, {}],
      rules: [
        {
          id: '',
          type: '',
          action: RuleAction.Reject,
          server: 'id-9',
        },
        {
          id: '',
          type: '',
          action: RuleAction.Route,
          server: '',
        },
      ],
    }))
  })
})
