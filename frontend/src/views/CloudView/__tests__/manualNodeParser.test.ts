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
})
