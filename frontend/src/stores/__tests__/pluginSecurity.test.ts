import { describe, it, expect, vi, beforeEach } from 'vitest'

const httpGet = vi.fn()
vi.mock('@/bridge', () => ({ HttpGet: (...args: any[]) => httpGet(...args) }))

import {
  assertAllowedPluginURL,
  clearPluginTrustConsent,
  confirmPluginFullTrust,
  fetchAllowedPluginCode,
  hasPluginTrustConsent,
  markPluginTrustConsent,
  sha256Hex,
  PluginSecurityError,
  PLUGIN_FULL_TRUST_ACCEPT_KEY,
  PLUGIN_FULL_TRUST_TITLE_KEY,
  PLUGIN_FULL_TRUST_WARNING_KEY,
  PLUGIN_TRUST_CONSENT_VERSION,
  pluginTrustWarningKey,
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
    await expect(fetchAllowedPluginCode('https://github.com/a/b/raw/main/x.js')).resolves.toBe(
      'CODE',
    )
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

describe('pluginTrustWarningKey', () => {
  it('returns the full-trust warning for a plain plugin', () => {
    expect(pluginTrustWarningKey({ id: 'plugin-x' })).toBe(PLUGIN_FULL_TRUST_WARNING_KEY)
  })

  it('still returns the FULL warning when a plugin declares capabilities (nothing enforces them)', () => {
    expect(pluginTrustWarningKey({ id: 'plugin-x', capabilities: ['network'] })).toBe(
      PLUGIN_FULL_TRUST_WARNING_KEY,
    )
    expect(pluginTrustWarningKey(undefined)).toBe(PLUGIN_FULL_TRUST_WARNING_KEY)
  })

  it('exposes distinct i18n keys for title and body', () => {
    expect(PLUGIN_FULL_TRUST_TITLE_KEY).not.toBe(PLUGIN_FULL_TRUST_WARNING_KEY)
    expect(PLUGIN_FULL_TRUST_TITLE_KEY).toMatch(/^plugins\./)
    expect(PLUGIN_FULL_TRUST_WARNING_KEY).toMatch(/^plugins\./)
  })
})

describe('hasPluginTrustConsent (legacy-data migration semantics)', () => {
  it('treats a record without the consent field as unconfirmed', () => {
    // Plugins persisted before the consent mechanism existed have no
    // trustConsentVersion at all — they must NOT be considered confirmed.
    expect(hasPluginTrustConsent({ id: 'legacy', name: 'Legacy Plugin' })).toBe(false)
    expect(hasPluginTrustConsent(undefined)).toBe(false)
    expect(hasPluginTrustConsent(null)).toBe(false)
  })

  it('treats malformed or stale consent versions as unconfirmed', () => {
    expect(hasPluginTrustConsent({ trustConsentVersion: '1' })).toBe(false)
    expect(hasPluginTrustConsent({ trustConsentVersion: 0 })).toBe(false)
    expect(
      hasPluginTrustConsent({ trustConsentVersion: PLUGIN_TRUST_CONSENT_VERSION - 1 }),
    ).toBe(false)
  })

  it('accepts only the exact current consent version', () => {
    expect(hasPluginTrustConsent({ trustConsentVersion: PLUGIN_TRUST_CONSENT_VERSION })).toBe(true)
    expect(
      hasPluginTrustConsent({ trustConsentVersion: PLUGIN_TRUST_CONSENT_VERSION + 1 }),
    ).toBe(false)
  })

  it('markPluginTrustConsent stamps the current version onto the record', () => {
    const plugin: Record<string, unknown> = { id: 'p' }
    markPluginTrustConsent(plugin)
    expect(plugin.trustConsentVersion).toBe(PLUGIN_TRUST_CONSENT_VERSION)
    expect(hasPluginTrustConsent(plugin)).toBe(true)
    clearPluginTrustConsent(plugin)
    expect(plugin.trustConsentVersion).toBeUndefined()
    expect(hasPluginTrustConsent(plugin)).toBe(false)
  })
})

describe('confirmPluginFullTrust', () => {
  it('shows the full-trust title/body with the accept okText by default', async () => {
    const confirmFn = vi.fn().mockResolvedValue(true)

    await expect(confirmPluginFullTrust(confirmFn, { id: 'p' })).resolves.toBe(true)

    expect(confirmFn).toHaveBeenCalledWith(
      PLUGIN_FULL_TRUST_TITLE_KEY,
      PLUGIN_FULL_TRUST_WARNING_KEY,
      { type: 'text', okText: PLUGIN_FULL_TRUST_ACCEPT_KEY },
    )
  })

  it('passes okText and body overrides through to the dialog', async () => {
    const confirmFn = vi.fn().mockResolvedValue(true)

    await confirmPluginFullTrust(confirmFn, { id: 'p' }, {
      okText: 'custom.okText',
      message: 'custom.body',
    })

    expect(confirmFn).toHaveBeenCalledWith(PLUGIN_FULL_TRUST_TITLE_KEY, 'custom.body', {
      type: 'text',
      okText: 'custom.okText',
    })
  })

  it('returns false when the dialog is cancelled (rejects)', async () => {
    const confirmFn = vi.fn().mockRejectedValue('common.canceled')
    await expect(confirmPluginFullTrust(confirmFn, { id: 'p' })).resolves.toBe(false)
  })

  it('returns false when the dialog resolves falsy', async () => {
    const confirmFn = vi.fn().mockResolvedValue(false)
    await expect(confirmPluginFullTrust(confirmFn, { id: 'p' })).resolves.toBe(false)
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
