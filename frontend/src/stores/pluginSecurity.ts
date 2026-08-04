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

// ---------------------------------------------------------------------------
// Full-trust disclosure
//
// Plugins are NOT sandboxed. Once installed and enabled they run as fully
// trusted code with the app's complete bridge access: they can read/write any
// file the app can, make arbitrary network requests, and execute native
// commands on this machine. There is no capability/permission manifest today,
// so the UI must always show the complete risk warning before a plugin is
// installed — if a manifest is ever introduced, a plugin that declares no
// capabilities must still default to this full warning.
// ---------------------------------------------------------------------------

// i18n keys for the informed-consent dialog shown before a plugin is added.
export const PLUGIN_FULL_TRUST_TITLE_KEY = 'plugins.fullTrustTitle'
export const PLUGIN_FULL_TRUST_WARNING_KEY = 'plugins.fullTrustWarning'
export const PLUGIN_FULL_TRUST_ACCEPT_KEY = 'plugins.fullTrustAccept'

// Version of the full-trust disclosure text/scope above. Each plugin records
// the version it was confirmed against (`trustConsentVersion`, persisted with
// the plugin config). Bump this constant whenever the disclosure materially
// changes and every plugin — including already-installed ones — will be walked
// through the dialog again before it may register or execute.
export const PLUGIN_TRUST_CONSENT_VERSION = 1

// Persisted consent marker. Kept as a standalone shape (instead of widening
// the Plugin type) so pre-consent plugin records — which simply lack the
// field — parse and type-check unchanged; a missing/invalid field just means
// "not confirmed yet".
export interface PluginTrustConsentRecord {
  trustConsentVersion?: number
}

// hasPluginTrustConsent reports whether `plugin` has confirmed the CURRENT
// full-trust disclosure. Records written before the consent mechanism existed
// have no `trustConsentVersion` at all; anything missing, non-numeric or
// older OR newer than the current version counts as unconfirmed. A future
// value can arrive only from untrusted/imported metadata or a newer app whose
// disclosure this build cannot know, so it must never grant consent here.
export const hasPluginTrustConsent = (plugin: unknown): boolean => {
  const version = (plugin as PluginTrustConsentRecord | null | undefined)?.trustConsentVersion
  return typeof version === 'number' && version === PLUGIN_TRUST_CONSENT_VERSION
}

// Consent is local security state, never plugin-supplied metadata. Call this
// on every external/imported plugin object before it can reach the consent
// check; only an already-persisted local record may later transfer consent to
// an updated record of the same plugin identity.
export const clearPluginTrustConsent = (plugin: object): void => {
  delete (plugin as PluginTrustConsentRecord).trustConsentVersion
}

// markPluginTrustConsent stamps `plugin` as having confirmed the current
// disclosure. The field is persisted alongside the rest of the plugin config.
// Takes `object` (not the weak PluginTrustConsentRecord type) so a fully
// typed Plugin — which predates the consent field — can be passed directly.
export const markPluginTrustConsent = (plugin: object): void => {
  ;(plugin as PluginTrustConsentRecord).trustConsentVersion = PLUGIN_TRUST_CONSENT_VERSION
}

// The dialog function is injected so this module stays free of UI imports
// (and trivially testable). Matches utils/interaction.ts `confirm`.
export type PluginTrustConfirmFn = (
  title: string,
  message: string,
  options?: { type: 'text' | 'markdown'; okText?: string; cancelText?: string },
) => Promise<unknown>

export interface PluginTrustDialogOverrides {
  // i18n key for the accept button; defaults to PLUGIN_FULL_TRUST_ACCEPT_KEY.
  okText?: string
  // i18n key for the dialog body; defaults to pluginTrustWarningKey(plugin).
  message?: string
}

// confirmPluginFullTrust is the SINGLE informed-consent dialog every plugin
// entry point must go through — the Plugin-Hub Install button, the manual
// File/Http plugin form, and the deferred prompt for plugins installed before
// this mechanism existed. Resolves true only on an explicit accept; a cancel,
// dismiss or falsy confirmation is a decline.
export const confirmPluginFullTrust = async (
  confirmFn: PluginTrustConfirmFn,
  plugin?: unknown,
  overrides: PluginTrustDialogOverrides = {},
): Promise<boolean> => {
  const body = overrides.message ?? pluginTrustWarningKey(plugin)
  const okText = overrides.okText ?? PLUGIN_FULL_TRUST_ACCEPT_KEY
  const accepted = await confirmFn(PLUGIN_FULL_TRUST_TITLE_KEY, body, {
    type: 'text',
    okText,
  }).catch(() => false)
  return Boolean(accepted)
}

// pluginTrustWarningKey returns the i18n key of the risk warning to show for
// `plugin`. Today every plugin gets the full-trust warning; a plugin object
// carrying a declared-capabilities field changes nothing because nothing
// enforces such declarations — undeclared and declared alike run fully
// trusted, and the warning must say so.
export const pluginTrustWarningKey = (_plugin?: unknown): string => {
  return PLUGIN_FULL_TRUST_WARNING_KEY
}

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
