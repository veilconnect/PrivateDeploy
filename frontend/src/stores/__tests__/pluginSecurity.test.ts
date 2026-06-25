import { describe, it, expect, vi, beforeEach } from 'vitest'

const httpGet = vi.fn()
vi.mock('@/bridge', () => ({ HttpGet: (...args: any[]) => httpGet(...args) }))

import {
  assertAllowedPluginURL,
  fetchAllowedPluginCode,
  sha256Hex,
  PluginSecurityError,
} from '../pluginSecurity'

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

describe('fetchAllowedPluginCode', () => {
  beforeEach(() => httpGet.mockReset())

  it('returns the body for a direct 200 from an allowlisted host', async () => {
    httpGet.mockResolvedValueOnce({ status: 200, headers: {}, body: 'CODE' })
    await expect(
      fetchAllowedPluginCode('https://raw.githubusercontent.com/a/b/main/x.js'),
    ).resolves.toBe('CODE')
    expect(httpGet).toHaveBeenCalledWith(
      'https://raw.githubusercontent.com/a/b/main/x.js',
      {},
      { Redirect: false },
    )
  })

  it('follows redirects that stay within the allowlist', async () => {
    httpGet
      .mockResolvedValueOnce({
        status: 302,
        headers: { Location: 'https://raw.githubusercontent.com/a/b/main/x.js' },
        body: '',
      })
      .mockResolvedValueOnce({ status: 200, headers: {}, body: 'CODE' })
    await expect(
      fetchAllowedPluginCode('https://github.com/a/b/raw/main/x.js'),
    ).resolves.toBe('CODE')
    expect(httpGet).toHaveBeenCalledTimes(2)
  })

  it('rejects an open redirect off the allowlist (the bypass this guards)', async () => {
    httpGet.mockResolvedValueOnce({
      status: 302,
      headers: { Location: 'https://evil.example.com/evil.js' },
      body: '',
    })
    await expect(
      fetchAllowedPluginCode('https://github.com/a/b/raw/main/x.js'),
    ).rejects.toBeInstanceOf(PluginSecurityError)
    // Never fetched the attacker URL's body.
    expect(httpGet).toHaveBeenCalledTimes(1)
  })

  it('rejects a redirect with no Location header', async () => {
    httpGet.mockResolvedValueOnce({ status: 301, headers: {}, body: '' })
    await expect(
      fetchAllowedPluginCode('https://raw.githubusercontent.com/a/b/main/x.js'),
    ).rejects.toBeInstanceOf(PluginSecurityError)
  })

  it('gives up after too many redirects', async () => {
    httpGet.mockResolvedValue({
      status: 302,
      headers: { Location: 'https://raw.githubusercontent.com/a/b/main/x.js' },
      body: '',
    })
    await expect(
      fetchAllowedPluginCode('https://raw.githubusercontent.com/a/b/main/x.js'),
    ).rejects.toBeInstanceOf(PluginSecurityError)
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
