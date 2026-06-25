// Security helpers for the plugin system.
//
// Plugins execute as untrusted code with full bridge access, so we add two
// low-friction defenses:
//   1. Remote plugin code may only be fetched over HTTPS from an allowlisted
//      host (where the official Plugin-Hub lives), preventing arbitrary-origin
//      and plaintext-HTTP code delivery / MITM.
//   2. Plugin code is pinned by SHA-256. The hash is recorded on first
//      install (trust-on-first-use); later drift (remote update or on-disk
//      tampering) is detected and must be re-approved before the code runs.

import { HttpGet } from '@/bridge'

// Hosts the GUI-for-Cores Plugin-Hub and its plugin sources are served from.
const ALLOWED_PLUGIN_HOSTS = new Set([
  'raw.githubusercontent.com',
  'github.com',
  'gist.githubusercontent.com',
  'objects.githubusercontent.com',
  'codeload.github.com',
])

export class PluginSecurityError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'PluginSecurityError'
  }
}

// assertAllowedPluginURL throws PluginSecurityError unless rawURL is HTTPS and
// hosted on an allowlisted host.
export const assertAllowedPluginURL = (rawURL: string): void => {
  let url: URL
  try {
    url = new URL(rawURL)
  } catch {
    throw new PluginSecurityError(`Invalid plugin URL: ${rawURL}`)
  }
  if (url.protocol !== 'https:') {
    throw new PluginSecurityError(`Plugin URL must use https:// — got ${url.protocol}//`)
  }
  if (!ALLOWED_PLUGIN_HOSTS.has(url.hostname)) {
    throw new PluginSecurityError(
      `Plugin host not allowed: ${url.hostname}. Allowed: ${[...ALLOWED_PLUGIN_HOSTS].join(', ')}`,
    )
  }
}

// fetchAllowedPluginCode downloads remote plugin code while enforcing the host
// allowlist on every hop. The bridge follows redirects transparently, so
// validating only the initial URL would let an open redirect on an allowlisted
// host (e.g. github.com) bounce the fetch to an arbitrary origin. We therefore
// disable automatic redirects and follow them manually, re-validating each
// Location against the allowlist before requesting it.
export const fetchAllowedPluginCode = async (rawURL: string): Promise<string> => {
  const MAX_HOPS = 5
  let current = rawURL
  for (let hop = 0; hop <= MAX_HOPS; hop++) {
    assertAllowedPluginURL(current)
    const { status, headers, body } = await HttpGet<string>(current, {}, { Redirect: false })
    if (status >= 300 && status < 400) {
      const raw = headers['Location'] ?? headers['location']
      const location = Array.isArray(raw) ? raw[0] : raw
      if (!location) {
        throw new PluginSecurityError(`Redirect without Location header from ${current}`)
      }
      current = new URL(location, current).toString()
      continue
    }
    if (status >= 200 && status < 300) {
      return body
    }
    throw new PluginSecurityError(`Plugin fetch failed (HTTP ${status}) from ${current}`)
  }
  throw new PluginSecurityError(`Too many redirects fetching plugin from ${rawURL}`)
}

// sha256Hex returns the lowercase hex SHA-256 of a UTF-8 string.
export const sha256Hex = async (text: string): Promise<string> => {
  const bytes = new TextEncoder().encode(text)
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}
