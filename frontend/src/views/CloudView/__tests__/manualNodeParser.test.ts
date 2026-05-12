import { describe, expect, it } from 'vitest'

import { parseImportedNodes } from '../manualNodeParser'

describe('manualNodeParser', () => {
  it('parses Shadowsocks links with base64 credentials and plain host section', () => {
    const result = parseImportedNodes('ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@203.0.113.10:8443#WizardManual')

    expect(result).toHaveLength(1)
    expect(result[0]).toMatchObject({
      label: 'WizardManual',
      ipv4: '203.0.113.10',
      ssPort: 8443,
      ssPassword: 'password',
    })
  })

  it('parses Shadowsocks links with fully base64-encoded payloads', () => {
    const result = parseImportedNodes('ss://YWVzLTI1Ni1nY206cGFzc3dvcmRAMS4yLjMuNDo4Mzg4#EncodedPayload')

    expect(result).toHaveLength(1)
    expect(result[0]).toMatchObject({
      label: 'EncodedPayload',
      ipv4: '1.2.3.4',
      ssPort: 8388,
      ssPassword: 'password',
    })
  })

  it('normalizes JSON imports with protocol fallbacks and boolean-like flags', () => {
    const result = parseImportedNodes(JSON.stringify([
      {
        name: 'Imported Node',
        ipv6: '2001:db8::10',
        region: 'nrt',
        plan: 'vc2-1c-1gb',
        port: '8388',
        password: 'ss-pass',
        hysteriaPort: '8443',
        hysteriaPassword: 'hy-pass',
        hysteriaSni: 'hy.example.com',
        hysteriaInsecure: 'yes',
        trojanPort: '443',
        trojanPassword: 'trojan-pass',
        trojanInsecure: 0,
      },
    ]))

    expect(result).toEqual([
      expect.objectContaining({
        label: 'Imported Node',
        ipv6: '2001:db8::10',
        region: 'nrt',
        plan: 'vc2-1c-1gb',
        ssPort: 8388,
        ssPassword: 'ss-pass',
        hysteriaPort: 8443,
        hysteriaPassword: 'hy-pass',
        hysteriaServerName: 'hy.example.com',
        hysteriaInsecure: true,
        trojanPort: 443,
        trojanPassword: 'trojan-pass',
        trojanInsecure: false,
      }),
    ])
  })

  it('parses trojan links with IPv6 endpoints and insecure flags', () => {
    const result = parseImportedNodes(
      'trojan://secret@[2001:db8::20]:443?sni=edge.example.com&allowInsecure=true#Trojan%20IPv6',
    )

    expect(result).toEqual([
      expect.objectContaining({
        label: 'Trojan IPv6',
        ipv6: '2001:db8::20',
        trojanPort: 443,
        trojanPassword: 'secret',
        trojanServerName: 'edge.example.com',
        trojanInsecure: true,
      }),
    ])
  })

  it('parses vless reality links with compact parameter aliases', () => {
    const result = parseImportedNodes(
      'vless://uuid-1234@203.0.113.30:443?pbk=public-key&sid=abcd&sni=reality.example.com#Reality',
    )

    expect(result).toEqual([
      expect.objectContaining({
        label: 'Reality',
        ipv4: '203.0.113.30',
        vlessPort: 443,
        vlessUUID: 'uuid-1234',
        vlessPublicKey: 'public-key',
        vlessShortId: 'abcd',
        vlessServerName: 'reality.example.com',
      }),
    ])
  })

  it('parses hysteria2 links with auth query fallback', () => {
    const result = parseImportedNodes(
      'hy2://203.0.113.40:8443?auth=hy-pass&sni=hy.example.com&insecure=off#Hysteria',
    )

    expect(result).toEqual([
      expect.objectContaining({
        label: 'Hysteria',
        ipv4: '203.0.113.40',
        hysteriaPort: 8443,
        hysteriaPassword: 'hy-pass',
        hysteriaServerName: 'hy.example.com',
        hysteriaInsecure: false,
      }),
    ])
  })
})
