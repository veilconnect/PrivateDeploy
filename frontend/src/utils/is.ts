import { parse } from 'yaml'

export const isValidBase64 = (str: string) => {
  if (typeof str !== 'string') return false
  if (str === '' || str.trim() === '') {
    return false
  }
  try {
    return btoa(atob(str)) == str
  } catch {
    return false
  }
}

export const isValidSubYAML = (str: string) => {
  if (typeof str !== 'string') return false
  try {
    const { proxies } = parse(str)
    return !!proxies
  } catch {
    return false
  }
}

export const isValidSubJson = (str: string) => {
  if (typeof str !== 'string') return false
  try {
    const { outbounds } = JSON.parse(str)
    return !!outbounds
  } catch {
    return false
  }
}

export const isValidPaylodYAML = (str: string) => {
  try {
    const { payload } = parse(str)
    return !!payload
  } catch {
    return false
  }
}

export const isValidRulesJson = (str: string) => {
  try {
    const { rules } = JSON.parse(str)
    return !!rules
  } catch {
    return false
  }
}

export const isValidIPv4 = (ip: string) =>
  /^((25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(25[0-5]|2[0-4]\d|[01]?\d\d?)$/.test(ip)

export const isValidIPv6 = (ip: string) => {
  if (typeof ip !== 'string') return false
  const normalized = ip.trim().replace(/^\[/, '').replace(/\]$/, '')
  if (!normalized) return false

  try {
    // Let the URL parser validate IPv6 grammar instead of a brittle mega-regex.
    const parsed = new URL(`http://[${normalized}]`)
    return parsed.hostname.startsWith('[') && parsed.hostname.endsWith(']')
  } catch {
    return false
  }
}

export const isValidJson = (str: string) => {
  try {
    return !!JSON.parse(str)
  } catch {
    return false
  }
}

export const isNumber = (v: any) => typeof v === 'number'
