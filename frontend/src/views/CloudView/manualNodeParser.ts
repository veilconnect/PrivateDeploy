import type { ManualNodeInput } from '@/stores/cloud/types'

const toOptionalPort = (value: string): number | undefined => {
  const trimmed = value.trim()
  if (!trimmed) return undefined
  const port = Number.parseInt(trimmed, 10)
  if (!Number.isFinite(port) || port <= 0 || port > 65535) return undefined
  return port
}

const decodeBase64 = (value: string): string => {
  try {
    const normalized = value.replace(/-/g, '+').replace(/_/g, '/')
    const padded = normalized + '='.repeat((4 - normalized.length % 4) % 4)
    if (typeof atob === 'function') {
      return atob(padded)
    }
    // @ts-expect-error - Buffer is available in Node contexts and polyfilled in browsers.
    return Buffer.from(padded, 'base64').toString('utf-8')
  } catch {
    return ''
  }
}

const parseBooleanLike = (value: unknown): boolean | undefined => {
  if (typeof value === 'boolean') {
    return value
  }
  if (typeof value === 'number') {
    if (value === 1) return true
    if (value === 0) return false
    return undefined
  }
  if (typeof value !== 'string') {
    return undefined
  }

  const normalized = value.trim().toLowerCase()
  if (!normalized) return undefined
  if (['1', 'true', 'yes', 'on'].includes(normalized)) return true
  if (['0', 'false', 'no', 'off'].includes(normalized)) return false
  return undefined
}

const normalizeHost = (host: string) => host.replace(/^\[/, '').replace(/\]$/, '')

const assignIpFields = (host: string): Partial<Pick<ManualNodeInput, 'ipv4' | 'ipv6'>> => {
  const normalized = normalizeHost(host)
  if (!normalized) {
    return {}
  }
  if (normalized.includes(':')) {
    return { ipv6: normalized }
  }
  return { ipv4: normalized }
}

const parseShadowSocksUrl = (text: string): ManualNodeInput | null => {
  let payload = text.slice('ss://'.length)
  let label = ''

  const hashIndex = payload.indexOf('#')
  if (hashIndex >= 0) {
    label = decodeURIComponent(payload.slice(hashIndex + 1))
    payload = payload.slice(0, hashIndex)
  }

  const queryIndex = payload.indexOf('?')
  if (queryIndex >= 0) {
    payload = payload.slice(0, queryIndex)
  }

  const decoded = decodeBase64(payload)
  if (!decoded || !decoded.includes('@')) {
    return null
  }

  const [methodPart, hostPart] = decoded.split('@')
  if (!hostPart) {
    return null
  }

  const [method, password] = methodPart.split(':')
  const [host, portStr] = hostPart.split(':')
  const port = toOptionalPort(portStr || '')
  if (!method || !password || !host || !port) {
    return null
  }

  return {
    label: label || host,
    ...assignIpFields(host),
    ssPort: port,
    ssPassword: password,
  }
}

const parseTrojanUrl = (text: string): ManualNodeInput | null => {
  try {
    const url = new URL(text)
    const host = url.hostname
    const port = toOptionalPort(url.port || '')
    const password = url.username

    if (!host || !port || !password) {
      return null
    }

    return {
      label: url.hash ? decodeURIComponent(url.hash.slice(1)) : host,
      ...assignIpFields(host),
      trojanPort: port,
      trojanPassword: decodeURIComponent(password),
      trojanServerName: url.searchParams.get('sni') || url.searchParams.get('peer') || undefined,
      trojanInsecure: parseBooleanLike(url.searchParams.get('allowInsecure') ?? url.searchParams.get('insecure')),
    }
  } catch {
    return null
  }
}

const parseVlessUrl = (text: string): ManualNodeInput | null => {
  try {
    const url = new URL(text)
    const host = url.hostname
    const port = toOptionalPort(url.port || '')
    const uuid = url.username

    if (!host || !port || !uuid) {
      return null
    }

    return {
      label: url.hash ? decodeURIComponent(url.hash.slice(1)) : host,
      ...assignIpFields(host),
      vlessPort: port,
      vlessUUID: decodeURIComponent(uuid),
      vlessPublicKey: url.searchParams.get('reality-public-key') || url.searchParams.get('pbk') || undefined,
      vlessShortId: url.searchParams.get('reality-short-id') || url.searchParams.get('sid') || undefined,
      vlessServerName: url.searchParams.get('sni') || undefined,
    }
  } catch {
    return null
  }
}

const parseHysteriaUrl = (text: string): ManualNodeInput | null => {
  try {
    const url = new URL(text)
    const host = url.hostname
    const port = toOptionalPort(url.port || '')
    const password = url.username || url.searchParams.get('auth') || url.searchParams.get('password') || ''

    if (!host || !port || !password) {
      return null
    }

    return {
      label: url.hash ? decodeURIComponent(url.hash.slice(1)) : host,
      ...assignIpFields(host),
      hysteriaPort: port,
      hysteriaPassword: decodeURIComponent(password),
      hysteriaServerName: url.searchParams.get('sni') || undefined,
      hysteriaInsecure: parseBooleanLike(url.searchParams.get('insecure') ?? url.searchParams.get('allowInsecure')),
    }
  } catch {
    return null
  }
}

const parseProtocolUrl = (text: string): ManualNodeInput | null => {
  const lower = text.toLowerCase()
  if (lower.startsWith('ss://')) {
    return parseShadowSocksUrl(text)
  }
  if (lower.startsWith('trojan://')) {
    return parseTrojanUrl(text)
  }
  if (lower.startsWith('vless://')) {
    return parseVlessUrl(text)
  }
  if (lower.startsWith('hysteria2://') || lower.startsWith('hy2://')) {
    return parseHysteriaUrl(text)
  }
  return null
}

const parseProtocolList = (raw: string): ManualNodeInput[] => {
  const matches = raw.match(/((ss|trojan|vless|hysteria2|hy2):\/\/[\S]+)/gi)
  if (!matches) {
    return []
  }

  const inputs: ManualNodeInput[] = []
  for (const entry of matches) {
    const parsed = parseProtocolUrl(entry.trim())
    if (parsed) {
      inputs.push(parsed)
    }
  }
  return inputs
}

export const parseImportedNodes = (raw: string): ManualNodeInput[] => {
  try {
    const data = JSON.parse(raw)
    const entries = Array.isArray(data) ? data : [data]
    const inputs: ManualNodeInput[] = []

    for (const item of entries) {
      if (!item || typeof item !== 'object') continue

      const record = item as Record<string, any>
      const label = String(record.label ?? record.name ?? '').trim()
      if (!label) continue

      const ipv4 = typeof record.ipv4 === 'string' ? record.ipv4.trim() : ''
      const ipv6 = typeof record.ipv6 === 'string' ? record.ipv6.trim() : ''

      inputs.push({
        label,
        ipv4: ipv4 || undefined,
        ipv6: ipv6 || undefined,
        region: typeof record.region === 'string' ? record.region : undefined,
        plan: typeof record.plan === 'string' ? record.plan : undefined,
        ssPort: toOptionalPort(String(record.ssPort ?? record.port ?? '')),
        ssPassword:
          typeof record.ssPassword === 'string' && record.ssPassword.trim()
            ? record.ssPassword.trim()
            : typeof record.password === 'string' && record.password.trim()
              ? record.password.trim()
              : undefined,
        hysteriaPort: toOptionalPort(String(record.hysteriaPort ?? '')),
        hysteriaPassword:
          typeof record.hysteriaPassword === 'string' && record.hysteriaPassword.trim()
            ? record.hysteriaPassword.trim()
            : undefined,
        hysteriaServerName:
          typeof record.hysteriaServerName === 'string' && record.hysteriaServerName.trim()
            ? record.hysteriaServerName.trim()
            : typeof record.hysteriaSni === 'string' && record.hysteriaSni.trim()
              ? record.hysteriaSni.trim()
              : undefined,
        hysteriaInsecure: parseBooleanLike(record.hysteriaInsecure),
        vlessPort: toOptionalPort(String(record.vlessPort ?? '')),
        vlessUUID:
          typeof record.vlessUUID === 'string' && record.vlessUUID.trim()
            ? record.vlessUUID.trim()
            : undefined,
        vlessPublicKey:
          typeof record.vlessPublicKey === 'string' && record.vlessPublicKey.trim()
            ? record.vlessPublicKey.trim()
            : undefined,
        vlessShortId:
          typeof record.vlessShortId === 'string' && record.vlessShortId.trim()
            ? record.vlessShortId.trim()
            : undefined,
        vlessServerName:
          typeof record.vlessServerName === 'string' && record.vlessServerName.trim()
            ? record.vlessServerName.trim()
            : typeof record.vlessSni === 'string' && record.vlessSni.trim()
              ? record.vlessSni.trim()
              : undefined,
        trojanPort: toOptionalPort(String(record.trojanPort ?? '')),
        trojanPassword:
          typeof record.trojanPassword === 'string' && record.trojanPassword.trim()
            ? record.trojanPassword.trim()
            : undefined,
        trojanServerName:
          typeof record.trojanServerName === 'string' && record.trojanServerName.trim()
            ? record.trojanServerName.trim()
            : typeof record.trojanSni === 'string' && record.trojanSni.trim()
              ? record.trojanSni.trim()
              : undefined,
        trojanInsecure: parseBooleanLike(record.trojanInsecure),
      })
    }

    if (inputs.length) {
      return inputs
    }
  } catch {
    // Fallback to protocol parsing below.
  }

  const protocolInputs = parseProtocolList(raw)
  if (protocolInputs.length) {
    return protocolInputs
  }

  throw new Error('invalid')
}
