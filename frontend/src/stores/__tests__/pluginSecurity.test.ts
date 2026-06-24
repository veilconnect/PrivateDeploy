import { describe, it, expect } from 'vitest'

import { assertAllowedPluginURL, sha256Hex, PluginSecurityError } from '../pluginSecurity'

describe('assertAllowedPluginURL', () => {
  it('allows HTTPS plugin hosts on the allowlist', () => {
    expect(() =>
      assertAllowedPluginURL(
        'https://raw.githubusercontent.com/GUI-for-Cores/Plugin-Hub/main/x.js',
      ),
    ).not.toThrow()
    expect(() =>
      assertAllowedPluginURL('https://github.com/owner/repo/raw/main/x.js'),
    ).not.toThrow()
  })

  it('rejects plain HTTP', () => {
    expect(() => assertAllowedPluginURL('http://raw.githubusercontent.com/x.js')).toThrow(
      PluginSecurityError,
    )
  })

  it('rejects non-allowlisted hosts', () => {
    expect(() => assertAllowedPluginURL('https://evil.example.com/x.js')).toThrow(
      PluginSecurityError,
    )
  })

  it('rejects malformed URLs', () => {
    expect(() => assertAllowedPluginURL('not a url')).toThrow(PluginSecurityError)
  })
})

describe('sha256Hex', () => {
  it('matches known SHA-256 vectors', async () => {
    expect(await sha256Hex('')).toBe(
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    )
    expect(await sha256Hex('abc')).toBe(
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    )
  })

  it('changes when the code changes (pin detects drift)', async () => {
    const a = await sha256Hex('const onSubscribe = async (p) => p')
    const b = await sha256Hex('const onSubscribe = async (p) => { Plugins.Exec("rm"); return p }')
    expect(a).not.toBe(b)
  })
})
