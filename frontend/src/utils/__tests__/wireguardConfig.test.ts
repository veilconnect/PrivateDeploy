import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it } from 'vitest'

import { Outbound } from '@/enums/kernel'
import i18n from '@/lang'

import { buildBuiltinProfiles } from '../builtinPresets'
import { DefaultOutbound } from '@/constant/profile'
import { generateConfig } from '../generator'

// Locate a sing-box binary for the optional `check` pass. Skipped (not failed)
// when unavailable, e.g. on CI runners without sing-box installed.
const singBox = process.env.SING_BOX_BIN || '/usr/local/bin/sing-box'
const hasSingBox = (() => {
  try {
    return existsSync(singBox)
  } catch {
    return false
  }
})()

const buildProfileWithWireGuard = () => {
  const profile = buildBuiltinProfiles()[0]
  profile.outbounds.push({
    ...DefaultOutbound(),
    id: 'wg-home',
    tag: 'home-wg',
    type: Outbound.WireGuard,
    server: '203.0.113.10',
    server_port: '51820',
    local_address: ['10.7.0.2/32'],
    private_key: '4FNO+XqF1hgreSRO0y23QWJ0OzK9LB1aaFFrsHHuelM=',
    peer_public_key: 'Ry0BhFWC0RurNuWXTmUDk8BGy67HRwOg2Z5JCUCI0Hk=',
    mtu: '1408',
    persistent_keepalive_interval: '25',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  return profile
}

describe('wireguard config generation', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    i18n.global.locale.value = 'en'
    window.AsyncFunction = Object.getPrototypeOf(async function () {})
      .constructor as typeof window.AsyncFunction
  })

  // Regression guard for the sing-box 1.12 WireGuard format. The mobile client
  // (sing-box v1.11 legacy outbound) broke because persistent_keepalive_interval
  // was emitted at the outbound top level — an unknown field that makes sing-box
  // reject the WHOLE config. Desktop must keep emitting WireGuard as an *endpoint*
  // with the keepalive inside the peer, never as a legacy outbound.
  it('emits WireGuard as a 1.12 endpoint with keepalive inside the peer', async () => {
    const config = await generateConfig(buildProfileWithWireGuard())

    const endpoints = (config.endpoints ?? []) as Array<Record<string, any>>
    const wg = endpoints.find((e) => e.tag === 'home-wg')
    expect(wg, 'WireGuard must be emitted as an endpoint').toBeTruthy()
    expect(wg!.type).toBe('wireguard')

    // Never leak the legacy outbound form into `outbounds`.
    const outbounds = (config.outbounds ?? []) as Array<Record<string, any>>
    expect(outbounds.some((o) => o.type === 'wireguard')).toBe(false)

    // keepalive belongs on the peer, NOT at the endpoint top level.
    expect(wg).not.toHaveProperty('persistent_keepalive_interval')
    const peer = (wg!.peers as Array<Record<string, any>>)[0]
    expect(peer).toBeTruthy()
    expect(peer.persistent_keepalive_interval).toBe(25)
    expect(peer.public_key).toBe('Ry0BhFWC0RurNuWXTmUDk8BGy67HRwOg2Z5JCUCI0Hk=')
  })

  it.skipIf(!hasSingBox)('passes `sing-box check` (real binary)', async () => {
    const config = await generateConfig(buildProfileWithWireGuard())
    const endpoints = config.endpoints as Array<Record<string, any>>

    // Wrap just the endpoint in a minimal, self-contained config so the check is
    // not tripped by local rule-set paths in the full generated profile.
    const minimal = {
      log: { level: 'warn' },
      endpoints,
      outbounds: [{ type: 'direct', tag: 'direct' }],
      route: { final: endpoints[0].tag },
    }
    const dir = mkdtempSync(join(tmpdir(), 'wgcheck-'))
    const file = join(dir, 'config.json')
    writeFileSync(file, JSON.stringify(minimal))

    // Throws (failing the test) if sing-box rejects the config.
    execFileSync(singBox, ['check', '-c', file], { stdio: 'pipe' })
  })
})
