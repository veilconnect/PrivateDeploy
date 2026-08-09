const normalizedKey = (key: string): string => key.toLowerCase().replace(/[^a-z0-9]/g, '')

const isSensitiveKey = (key: string): boolean => {
  const normalized = normalizedKey(key)
  if (!normalized) return false

  return [
    'password',
    'passwd',
    'passphrase',
    'token',
    'apikey',
    'accesskey',
    'privatekey',
    'publickey',
    'shortid',
    'uuid',
    'secret',
    'credential',
    'authorization',
    'bearer',
    'realitykey',
  ].some((marker) => normalized.includes(marker))
    || ['url', 'uri', 'link'].includes(normalized)
    || /(?:subscription|subscribe|share)(?:url|uri|link)/.test(normalized)
    || /(?:url|uri|link)(?:subscription|subscribe|share)/.test(normalized)
}

const looksLikeShareLink = (value: string): boolean =>
  /^(?:ss|ssr|vless|vmess|trojan|hysteria2?|hy2|tuic|socks5?):\/\//i.test(value.trim())

/**
 * Clone data before it is written to browser storage and remove credentials.
 *
 * Browser storage is plaintext and readable by every script running in the
 * WebView. The encrypted backend node record remains the source of truth for
 * protocol credentials; an offline cache only needs non-secret metadata.
 */
export const sanitizeForBrowserStorage = <T>(value: T): T => {
  const visit = (input: unknown): unknown => {
    if (typeof input === 'string') {
      return looksLikeShareLink(input) ? undefined : input
    }
    if (Array.isArray(input)) {
      return input
        .map((item) => visit(item))
        .filter((item) => item !== undefined)
    }
    if (!input || typeof input !== 'object') {
      return input
    }

    return Object.fromEntries(
      Object.entries(input as Record<string, unknown>)
        .filter(([key]) => !isSensitiveKey(key))
        .map(([key, item]) => [key, visit(item)])
        .filter(([, item]) => item !== undefined),
    )
  }

  return visit(value) as T
}

const legacySensitiveStorageKeys = [
  'offline-cache-nodes',
  'offline-cache-config',
  'offline-cache-regions',
  'offline-cache-plans',
  'auto-backup',
] as const

/** Proactively migrate caches written by older versions, even if no feature
 * ever reads that key again. Invalid legacy blobs are removed rather than left
 * as an indefinite plaintext credential store. */
export const migrateSensitiveBrowserStorage = (
  storage: Pick<Storage, 'getItem' | 'setItem' | 'removeItem'> = localStorage,
): { migrated: number; removed: number } => {
  let migrated = 0
  let removed = 0
  for (const key of legacySensitiveStorageKeys) {
    const raw = storage.getItem(key)
    if (raw === null) continue
    try {
      const parsed = JSON.parse(raw) as unknown
      if (!parsed || typeof parsed !== 'object') throw new Error('invalid cache object')
      storage.setItem(key, JSON.stringify(sanitizeForBrowserStorage(parsed)))
      migrated += 1
    } catch {
      storage.removeItem(key)
      removed += 1
    }
  }
  return { migrated, removed }
}
